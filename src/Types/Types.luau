--!strict
-- Shared public configuration, statistics and error types.

export type PriorityName = "Critical" | "High" | "Normal" | "Low" | "Background"

export type ErrorObject = {
	Code: string,
	Message: string,
	Details: any?,
}

export type ProtocolLimits = {
	MaxBatchMessages: number?,
	MaxNameLength: number?,
	MaxRequestIdLength: number?,
}

export type PayloadLimits = {
	MaxBytes: number?,
	MaxDepth: number?,
}

export type BatchingConfig = {
	MaxBatchSize: number?,
	MaxBatchBytes: number?,
	MaxQueueDepth: number?,
	FlushInterval: number?,
	Adaptive: boolean?,
	MaxLatency: number?,
	AdaptiveDepthThreshold: number?,
	UnreliableBatchSize: number?,
	UnreliableMaxBytes: number?,
}

export type RequestConfig = {
	Timeout: number?,
	MaxAttempts: number?,
	BackoffBase: number?,
	BackoffMax: number?,
	Jitter: number?,
	DedupeTtl: number?,
	DedupeMaxEntries: number?,
	Random: (() -> number)?,
}

export type RateLimitConfig = {
	Rate: number?,
	Burst: number?,
	PacketRate: number?,
	PacketBurst: number?,
}

export type SerializerConfig = {
	Enabled: boolean?,
	FallbackToNative: boolean?,
	Limits: any?,
}

export type CompressionConfig = {
	Enabled: boolean?,
	Threshold: number?,
	MinSavingsRatio: number?,
	MaxDecompressedBytes: number?,
	Codec: any?,
}

export type NetworkConfig = {
	Name: string?,
	Preset: "Minimal" | "Standard" | "Hardened"?,
	Stats: boolean?,
	Batch: BatchingConfig?,
	Request: RequestConfig?,
	RateLimit: RateLimitConfig?,
	Payload: PayloadLimits?,
	Limits: ProtocolLimits?,
	Serializer: SerializerConfig?,
	Compression: CompressionConfig?,
}

export type NetworkStats = {
	PacketsSent: number,
	PacketsReceived: number,
	MessagesSent: number,
	MessagesReceived: number,
	BatchesSent: number,
	AverageBatchSize: number,
	OutboundRejected: number,
	QueueOverflow: number,
	BytesSentEstimate: number,
	CompressionSavingsBytes: number,
	QueueDepth: number,
	RequestsSent: number,
	RequestsPending: number,
	RequestsTimedOut: number,
	Retries: number,
	MalformedPackets: number,
	DroppedPackets: number,
	RateLimited: number,
	MiddlewareRejected: number,
	PermissionsDenied: number,
	PayloadRejected: number,
	Dispatches: number,
	DispatchTimeMs: number,
	AverageDispatchTimeMs: number,
	MessagesByPriority: { number },
}

return {}
