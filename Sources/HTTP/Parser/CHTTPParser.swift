import Transport
import CHTTP
import URI

/// Internal CHTTP parser protocol
internal protocol CHTTPParser: class {
    associatedtype StreamType: ReadableStream
    var stream: StreamType { get }
    var parser: http_parser { get set }
    var settings: http_parser_settings { get set }
    var buffer: Bytes { get set }
}

extension CHTTPParser {
    /// Parses a generic CHTTP message, filling the
    /// ParseResults object attached to the C praser.
    internal func parseMessage() throws -> ParseResults {
        // create a new results object and set
        // a reference to it on the parser
        var results = ParseResults()
        ParseResults.set(&results, on: &parser)
        
        // called when chunks of the url have been read
        settings.on_url = { parser, chunk, length in
            guard
                let results = ParseResults.get(from: parser),
                let bytes = chunk?.makeBytes(length: length)
            else {
                // signal an error
                return 1
            }
            
            // append the url bytes to the results
            results.url += bytes
            return 0
        }
        
        // called when chunks of a header field have been read
        settings.on_header_field = { parser, chunk, length in
            guard
                let results = ParseResults.get(from: parser),
                let bytes = chunk?.makeBytes(length: length)
            else {
                // signal an error
                return 1
            }
            
            // check current header parsing state
            switch results.headerState {
            case .none:
                // nothing is being parsed, start a new key
                results.headerState = .key(bytes)
            case .value(let key, let value):
                // there was previously a value being parsed.
                // it is now finished.
                results.headers[key] = value.makeString()
                // start a new key
                results.headerState = .key(bytes)
            case .key(let key):
                // there is a key currently being parsed.
                // add the new bytes to it.
                results.headerState = .key(key + bytes)
            }
            
            return 0
        }
        
        // called when chunks of a header value have been read
        settings.on_header_value = { parser, chunk, length in
            guard
                let results = ParseResults.get(from: parser),
                let bytes = chunk?.makeBytes(length: length)
            else {
                // signal an error
                return 1
            }
            
            // check the current header parsing state
            switch results.headerState {
            case .none:
                // nothing has been parsed, so this
                // value is useless. 
                // (this should never be reached)
                results.headerState = .none
            case .value(let key, let value):
                // there was previously a value being parsed.
                // add the new bytes to it.
                results.headerState = .value(key: key, value + bytes)
            case .key(let key):
                // there was previously a key being parsed.
                // it is now finished.
                let headerKey = HeaderKey(key.makeString())
                // add the new bytes alongside the created key
                results.headerState = .value(key: headerKey, bytes)
            }
            
            return 0
        }
        
        // called when header parsing has completed
        settings.on_headers_complete = { parser in
            guard let results = ParseResults.get(from: parser) else {
                // signal an error
                return 1
            }
            
            // check the current header parsing state
            switch results.headerState {
            case .value(let key, let value):
                // there was previously a value being parsed.
                // it should be added to the headers dict.
                results.headers[key] = value.makeString()
            default:
                // no other cases need to be handled.
                break
            }
            
            return 0
        }
        
        // called when chunks of the body have been read
        settings.on_body = { parser, chunk, length in
            guard
                let results = ParseResults.get(from: parser),
                let bytes = chunk?.makeBytes(length: length)
            else {
                // signal an error
                return 1
            }
            
            // append the body chunks to the results
            results.body += bytes
            return 0
        }
        
        // called when the message is finished parsing
        settings.on_message_complete = { parser in
            guard
                let parser = parser,
                let results = ParseResults.get(from: parser)
            else {
                // signal an error
                return 1
            }
            
            // mark the results as complete
            results.isComplete = true
            
            // parse version
            let major = Int(parser.pointee.http_major)
            let minor = Int(parser.pointee.http_minor)
            results.version = Version(major: major, minor: minor)
            
            return 0
        }
        
        // loops until the results are marked as completed
        while !results.isComplete {
            // read bytes from the stream into the buffer
            let bytesRead = try stream.read(max: buffer.capacity, into: &buffer)
            
            // if EOF is reached, we do not need to continue parsing
            if bytesRead == 0 {
                throw ParserError.streamEmpty
            }
            
            // cast the buffer
            guard let pointer = buffer.makeCPointer() else {
                throw ParserError.streamEmpty
            }
            
            // call the CHTTP parser
            let parsedCount = http_parser_execute(&parser, &settings, pointer, bytesRead)
            
            // if the parsed count does not equal the bytes passed
            // to the parser, it is signaling an error
            guard parsedCount == bytesRead else {
                throw ParserError.invalidMessage
            }
        }
        
        // return the results of the parsing
        return results
    }

    // parses a peer address from a given stream
    // and headers
    func parsePeerAddress<Stream: InternetStream>(
        from stream: Stream,
        with headers: [HeaderKey: String]
    ) -> PeerAddress {
        let forwarded = headers["Forwarded"]
        let xForwardedFor = headers["X-Forwarded-For"]
        
        let streamAddress = "\(stream.hostname):\(stream.port)"
        
        return PeerAddress(
            forwarded: forwarded,
            xForwardedFor: xForwardedFor,
            stream: streamAddress
        )
    }
}

// MARK: Utilities

extension Array where Iterator.Element == Byte {
    /// Creates a C pointer from a Bytes array
    func makeCPointer() -> UnsafePointer<CChar>? {
        return withUnsafeBytes { rawPointer in
            return rawPointer.baseAddress?.assumingMemoryBound(to: Int8.self)
        }
    }
}

extension UnsafePointer where Pointee == CChar {
    /// Creates a Bytes array from a C pointer
    func makeBytes(length: Int) -> Bytes {
        let pointer = UnsafeBufferPointer(start: self, count: length)
        
        return pointer.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: length) { pointer in
            let buffer = UnsafeBufferPointer(start: pointer, count: length)
            return Array(buffer)
            } ?? []
    }
    
    /// Creates a String from a C pointer
    func makeString(length: Int) -> String {
        return makeBytes(length: length).makeString()
    }
}
