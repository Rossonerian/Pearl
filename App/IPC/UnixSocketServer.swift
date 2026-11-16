import Foundation
import PearlCore

/// Asynchronous Unix Domain Socket Server for Pearl.
///
/// Features:
/// - Fully asynchronous `async`/`await` request processing without thread blocking or semaphores.
/// - Length-safe read loop supporting messages up to `maxRequestBytes` (64 KB).
/// - Socket timeout enforcement (`SO_RCVTIMEO` and `SO_SNDTIMEO`).
/// - Strict POSIX permission enforcement (`0700` directory, `0600` socket file).
/// - Safe lifecycle handling with graceful shutdown and stale socket unlink.
public final class UnixSocketServer: @unchecked Sendable {
    public static let maxRequestBytes = 65536 // 64 KB limit
    public static let defaultTimeoutSeconds = 2.0
    
    private let socketPath: String
    private var serverSource: DispatchSourceRead?
    private var serverFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.pearl.ipc.server", qos: .userInteractive)
    
    public var onCommandHandler: (@Sendable (IPCRequest) async -> IPCResponse)?
    
    public init(socketPath: String) {
        self.socketPath = socketPath
    }
    
    public func start() throws {
        let parentDir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        _ = chmod(parentDir.path, 0o700)
        
        // Remove any stale socket file before binding
        unlink(socketPath)
        
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        
        let flags = fcntl(serverFD, F_GETFL, 0)
        _ = fcntl(serverFD, F_SETFL, flags | O_NONBLOCK)
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(serverFD)
            throw POSIXError(.ENAMETOOLONG)
        }
        
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }
        
        let oldUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(serverFD, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        chmod(socketPath, 0o600)
        umask(oldUmask)
        
        guard bindResult == 0 else {
            let err = errno
            close(serverFD)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        
        guard listen(serverFD, 16) == 0 else {
            let err = errno
            close(serverFD)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 {
                close(fd)
            }
            if let path = self?.socketPath {
                unlink(path)
            }
        }
        source.resume()
        serverSource = source
    }
    
    public func stop() {
        serverSource?.cancel()
        serverSource = nil
        serverFD = -1
    }
    
    private func acceptConnections() {
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(serverFD, saPtr, &clientLen)
                }
            }
            
            if clientFD < 0 {
                break
            }
            
            var opt: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))
            
            // Clear non-blocking on accepted client FD
            let flags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
            
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            
            Task { [weak self] in
                await self?.handleClientAsync(fd: clientFD)
            }
        }
    }
    
    private func handleClientAsync(fd: Int32) async {
        defer { close(fd) }
        
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        
        // Read data until we have a decodable IPCRequest or hit maxRequestBytes
        while requestData.count < Self.maxRequestBytes {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }
            requestData.append(buffer, count: bytesRead)
            
            // Attempt decoding if we have data
            if (try? JSONDecoder().decode(IPCRequest.self, from: requestData)) != nil {
                break
            }
        }
        
        guard !requestData.isEmpty else { return }
        
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(IPCRequest.self, from: requestData) else {
            let errResp = IPCResponse(id: "error", success: false, message: "Invalid JSON-RPC request payload")
            if let data = try? JSONEncoder().encode(errResp) {
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
            }
            return
        }
        
        let response: IPCResponse
        if let handler = onCommandHandler {
            response = await handler(request)
        } else {
            response = IPCResponse(id: request.id, success: false, message: "No command handler registered")
        }
        
        if let respData = try? JSONEncoder().encode(response) {
            _ = respData.withUnsafeBytes { write(fd, $0.baseAddress!, respData.count) }
        }
    }
}
