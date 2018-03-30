import Core
import Dispatch

/// Represents an HTTP Message's Body.
///
/// This can contain any data and should match the Message's "Content-Type" header.
///
/// [Learn More →](https://docs.vapor.codes/3.0/http/body/)
public struct HTTPBody {
    /// The underlying storage type
    var storage: HTTPBodyStorage

    /// Internal HTTPBody init with underlying storage type.
    internal init(storage: HTTPBodyStorage) {
        self.storage = storage
    }

    /// Creates an empty HTTP body
    public init() {
        self.storage = .none
    }

    /// Create a new body wrapping `Data`.
    public init(data: Data) {
        storage = .data(data)
    }

    /// Create a new body wrapping `DispatchData`.
    public init(dispatchData: DispatchData) {
        storage = .dispatchData(dispatchData)
    }

    /// Create a new body from the UTF-8 representation of a StaticString
    public init(staticString: StaticString) {
        storage = .staticString(staticString)
    }

    /// Create a new body from the UTF-8 representation of a string
    public init(string: String) {
        self.storage = .string(string)
    }

    /// Create a new body from an `HTTPChunkedStream`
    public init(chunked: HTTPChunkedStream) {
        self.storage = .chunkedStream(chunked)
    }

    /// Create a new body from a `ByteBuffer`
    public init(buffer: ByteBuffer) {
        self.storage = .buffer(buffer)
    }

    /// Get body data.
    public var data: Data? {
        return storage.data
    }

    /// The size of the data buffer
    public var count: Int? {
        return self.storage.count
    }

    /// Consumes the HTTP body, if it is a stream.
    /// Otherwise, returns the same value as `.data`.
    /// - parameters:
    ///     - max: The maximum streaming body size to allow.
    ///            This only applies to streaming bodies, like chunked streams.
    ///     - worker: The event loop to perform this async work on.
    public func consumeData(max: Int, on worker: Worker) -> Future<Data> {
        return storage.consumeData(max: max, on: worker)
    }

    /// See `consumeData(max:on:)`
    @available(*, deprecated, renamed: "consumeData(max:on:)")
    public func makeData(max: Int) -> Future<Data> {
        return consumeData(max: max, on: EmbeddedEventLoop())
    }
}

/// Can be converted to an HTTP body.
///
/// [Learn More →](https://docs.vapor.codes/3.0/http/body/#bodyrepresentable)
public protocol HTTPBodyRepresentable {
    /// Convert to an HTTP body.
    func makeBody() throws -> HTTPBody
}

/// String can be represented as an HTTP body.
extension String: HTTPBodyRepresentable {
    /// See BodyRepresentable.makeBody()
    public func makeBody() throws -> HTTPBody {
        return HTTPBody(string: self)
    }
}

extension HTTPBody: CustomStringConvertible {
    /// See `CustomStringConvertible.description`
    public var description: String {
        switch storage {
        case .data, .buffer, .dispatchData, .staticString, .string, .none: return debugDescription
        case .chunkedStream(let stream):
            guard !stream.isClosed else {
                return debugDescription
            }
            return "<chunked stream, use `debugPrint(_:)` to consume>"
        }
    }
}

extension HTTPBody: CustomDebugStringConvertible {
    /// See `CustomDebugStringConvertible.debugDescription`
    public var debugDescription: String {
        switch storage {
        case .none: return "<no body>"
        case .buffer(let buffer): return buffer.getString(at: 0, length: buffer.readableBytes) ?? "n/a"
        case .data(let data): return String(data: data, encoding: .ascii) ?? "n/a"
        case .dispatchData(let data): return String(data: Data(data), encoding: .ascii) ?? "n/a"
        case .staticString(let string): return string.description
        case .string(let string): return string
        case .chunkedStream(let stream):
            guard !stream.isClosed else {
                return "<consumed chunk stream>"
            }
            do {
                let data = try stream.drain(max: 1_000_000).wait()
                return String(data: data, encoding: .utf8) ?? "n/a"
            } catch {
                return "<chunked stream error: \(error)>"
            }
        }
    }
}

/// The internal storage medium.
///
/// NOTE: This is an implementation detail
enum HTTPBodyStorage {
    case none
    case buffer(ByteBuffer)
    case data(Data)
    case staticString(StaticString)
    case dispatchData(DispatchData)
    case string(String)
    case chunkedStream(HTTPChunkedStream)

    /// The size of the HTTP body's data.
    /// `nil` of the body is a non-determinate stream.
    var count: Int? {
        switch self {
        case .data(let data): return data.count
        case .dispatchData(let data): return data.count
        case .staticString(let staticString): return staticString.utf8CodeUnitCount
        case .string(let string): return string.utf8.count
        case .buffer(let buffer): return buffer.readableBytes
        case .chunkedStream: return nil
        case .none: return 0
        }
    }

    var data: Data? {
        switch self {
        case .buffer(let buffer): return buffer.getData(at: 0, length: buffer.readableBytes)
        case .data(let data): return data
        case .dispatchData(let dispatch): return Data(dispatch)
        case .staticString(let string): return Data(bytes: string.utf8Start, count: string.utf8CodeUnitCount)
        case .string(let string): return Data(string.utf8)
        case .chunkedStream: return nil
        case .none: return nil
        }
    }

    func consumeData(max: Int, on worker: Worker) -> Future<Data> {
        if let data = self.data {
            return Future.map(on: worker) { data }
        } else {
            switch self {
            case .chunkedStream(let stream): return stream.drain(max: max)
            case .none: return Future.map(on: worker) { Data() }
            default: fatalError("Unexpected HTTP body storage: \(self)")
            }
        }
    }
}
