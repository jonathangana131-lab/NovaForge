#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("AgentPolicy requires a POSIX libc")
#endif

@inline(__always)
func policyPOSIXRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
#if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
#elseif canImport(Glibc)
    Glibc.read(descriptor, buffer, count)
#endif
}
