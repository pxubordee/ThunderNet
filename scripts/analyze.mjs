#!/usr/bin/env node
/**
 * Strict cross-module type checking without Roblox-specific tooling:
 *  - mirrors src/ into .analyze/src
 *  - rewrites require(script.Parent...) into relative string requires
 *  - shadows Roblox globals with typed `any` locals
 *  - runs `luau-analyze --mode=strict` over every generated module
 *
 * This validates our own annotations and cross-module type exports. It does not
 * validate Roblox API usage (that requires Studio/luau-lsp with Roblox defs).
 */
import { readFileSync, readdirSync, statSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join, relative, dirname, sep, posix } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const srcRoot = join(repoRoot, "src");
const outRoot = join(repoRoot, ".analyze");
const outSrc = join(outRoot, "src");

function walk(dir) {
	const files = [];
	for (const entry of readdirSync(dir)) {
		const full = join(dir, entry);
		const stat = statSync(full);
		if (stat.isDirectory()) files.push(...walk(full));
		else if (entry.endsWith(".luau")) files.push(full);
	}
	return files;
}

const PRELUDE = `-- Generated analysis prelude: shadows Roblox globals for the standalone analyzer.
local game: any = nil :: any
local script: any = nil :: any
local Instance: any = nil :: any
local task: any = nil :: any
local warn: (...any) -> () = nil :: any
local typeof: (any) -> string = nil :: any
local bit32: any = nil :: any
local buffer: any = nil :: any
local Vector2: any = nil :: any
local Vector3: any = nil :: any
local CFrame: any = nil :: any
local Color3: any = nil :: any
local UDim: any = nil :: any
local UDim2: any = nil :: any
`;

rmSync(outRoot, { recursive: true, force: true });
mkdirSync(outSrc, { recursive: true });

const sourceFiles = walk(srcRoot);

// Build the virtual Rojo tree. A directory containing init.luau is itself a
// module; every other .luau file is a module child of its directory.
const nodes = new Map(); // id -> { type: "folder" | "module", relFile?: string }
function ensureFolder(id) {
	if (!nodes.has(id)) nodes.set(id, { type: "folder" });
	return nodes.get(id);
}
ensureFolder("ThunderNet");

for (const full of sourceFiles) {
	const rel = relative(srcRoot, full).split(sep).join("/");
	const segments = rel.split("/");
	const isInit = segments[segments.length - 1] === "init.luau";
	let id = "ThunderNet";
	for (const dir of segments.slice(0, -1)) {
		id = id + "/" + dir;
		ensureFolder(id);
	}
	if (isInit) {
		const node = ensureFolder(id);
		node.type = "module";
		node.relFile = rel;
	} else {
		const name = segments[segments.length - 1].slice(0, -5);
		nodes.set(id + "/" + name, { type: "module", relFile: rel });
	}
}

function scriptNodeIdForFile(rel) {
	const segments = rel.split("/");
	const last = segments[segments.length - 1];
	const dirs = segments.slice(0, -1);
	if (last === "init.luau") {
		return dirs.length === 0 ? "ThunderNet" : "ThunderNet/" + dirs.join("/");
	}
	return "ThunderNet/" + dirs.concat(last.slice(0, -5)).join("/");
}

function resolveScriptPath(scriptId, pathSegments) {
	let id = scriptId;
	for (const segment of pathSegments) {
		if (segment === "Parent") {
			const slash = id.lastIndexOf("/");
			if (slash < 0) throw new Error(`.Parent escapes the ThunderNet root at ${id}`);
			id = id.slice(0, slash);
		} else {
			const childId = id + "/" + segment;
			if (!nodes.has(childId)) throw new Error(`Cannot resolve .${segment} from ${id}`);
			id = childId;
		}
	}
	return id;
}

const REQUIRE_PATTERN = /require\s*\(\s*script((?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)+)\s*\)/g;

const rewriteErrors = [];
let rewrittenCount = 0;

for (const full of sourceFiles) {
	const rel = relative(srcRoot, full).split(sep).join("/");
	let source = readFileSync(full, "utf8");

	source = source.replace(REQUIRE_PATTERN, (match, rawPath) => {
		const segments = rawPath
			.split(".")
			.map((part) => part.trim())
			.filter(Boolean);
		let targetId;
		try {
			targetId = resolveScriptPath(scriptNodeIdForFile(rel), segments);
		} catch (error) {
			rewriteErrors.push(`${rel}: failed to rewrite require(${rawPath.trim()}): ${error.message}`);
			return match;
		}
		const target = nodes.get(targetId);
		if (!target || target.type !== "module" || !target.relFile) {
			rewriteErrors.push(`${rel}: require target ${targetId} is not a module`);
			return match;
		}
		let relativePath = posix.relative(posix.dirname(rel), target.relFile.replace(/\.luau$/, ""));
		if (!relativePath.startsWith(".")) relativePath = "./" + relativePath;
		rewrittenCount += 1;
		return `require("${relativePath}")`;
	});

	let header = "";
	const directive = source.match(/^--!(strict|nonstrict)\r?\n/);
	if (directive) {
		header = directive[0];
		source = source.slice(header.length);
	}
	const outRel = rel === "init.luau" ? "Package.luau" : rel;
	const outPath = join(outSrc, outRel);
	mkdirSync(dirname(outPath), { recursive: true });
	writeFileSync(outPath, header + PRELUDE + source);
}

if (rewriteErrors.length > 0) {
	for (const message of rewriteErrors) console.error(message);
	process.exit(1);
}

const outFiles = walk(outSrc);
console.log(`analyzing ${outFiles.length} modules (${rewrittenCount} requires rewritten)...`);
try {
	const relativeOutFiles = outFiles.map((file) => relative(outSrc, file));
	const output = execFileSync("luau-analyze", ["--mode=strict", ...relativeOutFiles], {
		cwd: outSrc,
		encoding: "utf8",
		stdio: ["ignore", "pipe", "pipe"],
	});
	if (output.trim().length > 0) console.log(output.trim());
	console.log("analysis clean");
} catch (error) {
	const stderr = (error.stderr || "").toString().trim();
	const stdout = (error.stdout || "").toString().trim();
	const combined = [stdout, stderr].filter(Boolean).join("\n");
	const preludeNames = "game|script|Instance|task|warn|typeof|bit32|buffer|Vector2|Vector3|CFrame|Color3|UDim|UDim2";
	const noise = new RegExp(`LocalUnused: Variable '(${preludeNames})' is never used`);
	const relevant = combined
		.split("\n")
		.filter((line) => !noise.test(line))
		.join("\n")
		.trim();
	if (relevant.length === 0) {
		console.log("analysis clean");
		process.exit(0);
	}
	console.error(relevant);
	console.error("analysis found issues");
	process.exit(1);
}
