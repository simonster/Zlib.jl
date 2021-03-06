
module Zlib

import Base: read, write, close, eof

export compress, decompress, crc32

const Z_NO_FLUSH      = 0
const Z_PARTIAL_FLUSH = 1
const Z_SYNC_FLUSH    = 2
const Z_FULL_FLUSH    = 3
const Z_FINISH        = 4
const Z_BLOCK         = 5
const Z_TREES         = 6

const Z_OK            = 0
const Z_STREAM_END    = 1
const Z_NEED_DICT     = 2
const ZERRNO          = -1
const Z_STREAM_ERROR  = -2
const Z_DATA_ERROR    = -3
const Z_MEM_ERROR     = -4
const Z_BUF_ERROR     = -5
const Z_VERSION_ERROR = -6

@unix_only const libz = "libz"
@windows_only const libz = "zlib1"

# The zlib z_stream structure.
type z_stream
    next_in::Ptr{Uint8}
    avail_in::Cuint
    total_in::Culong

    next_out::Ptr{Uint8}
    avail_out::Cuint
    total_out::Culong

    msg::Ptr{Uint8}
    state::Ptr{Void}

    zalloc::Ptr{Void}
    zfree::Ptr{Void}
    opaque::Ptr{Void}

    data_type::Cint
    adler::Culong
    reserved::Culong

    function z_stream()
        strm = new()
        strm.next_in   = C_NULL
        strm.avail_in  = 0
        strm.total_in  = 0
        strm.next_out  = C_NULL
        strm.avail_out = 0
        strm.total_out = 0
        strm.msg       = C_NULL
        strm.state     = C_NULL
        strm.zalloc    = C_NULL
        strm.zfree     = C_NULL
        strm.opaque    = C_NULL
        strm.data_type = 0
        strm.adler     = 0
        strm.reserved  = 0
        strm
    end
end

type gz_header
    text::Cint          # true if compressed data believed to be text
    time::Culong        # modification time
    xflags::Cint        # extra flags (not used when writing a gzip file)
    os::Cint            # operating system
    extra::Ptr{Uint8}   # pointer to extra field or Z_NULL if none
    extra_len::Cuint    # extra field length (valid if extra != Z_NULL)
    extra_max::Cuint    # space at extra (only when reading header)
    name::Ptr{Uint8}    # pointer to zero-terminated file name or Z_NULL
    name_max::Cuint     # space at name (only when reading header)
    comment::Ptr{Uint8} # pointer to zero-terminated comment or Z_NULL
    comm_max::Cuint     # space at comment (only when reading header)
    hcrc::Cint          # true if there was or will be a header crc
    done::Cint          # true when done reading gzip header (not used
                        # when writing a gzip file)
    gz_header() = new(0,0,0,0,0,0,0,0,0,0,0,0,0)
end

function zlib_version()
    ccall((:zlibVersion, libz), Ptr{Uint8}, ())
end

type Writer <: IO
    strm::z_stream
    io::IO
    closed::Bool

    Writer(strm::z_stream, io::IO, closed::Bool) =
        (w = new(strm, io, closed); finalizer(w, close); w)
end

function Writer(io::IO, level::Integer, gzip::Bool=false, raw::Bool=false)
    if !(1 <= level <= 9)
        error("Invalid zlib compression level.")
    end

    strm = z_stream()
    ret = ccall((:deflateInit2_, libz),
                Int32, (Ptr{z_stream}, Cint, Cint, Cint, Cint, Cint, Ptr{Uint8}, Int32),
                &strm, level, 8, raw? -15 : 15+gzip*16, 8, 0, zlib_version(), sizeof(z_stream))

    if ret != Z_OK
        error("Error initializing zlib deflate stream.")
    end

    if gzip && false
        hdr = gz_header()
        ret = ccall((:deflateSetHeader, libz),
            Cint, (Ptr{z_stream}, Ptr{gz_header}),
            &strm, &hdr)
        if ret != Z_OK
            error("Error setting gzip stream header.")
        end
    end

    Writer(strm, io, false)
end

Writer(io::IO, gzip::Bool=false, raw::Bool=false) = Writer(io, 9, gzip, raw)

function write(w::Writer, p::Ptr, nb::Integer)
    w.strm.next_in = p
    w.strm.avail_in = nb
    outbuf = Array(Uint8, 1024)

    while true
        w.strm.avail_out = length(outbuf)
        w.strm.next_out = outbuf

        ret = ccall((:deflate, libz),
                    Int32, (Ptr{z_stream}, Int32),
                    &w.strm, Z_NO_FLUSH)
        if ret != Z_OK
            error("Error in zlib deflate stream ($(ret)).")
        end

        n = length(outbuf) - w.strm.avail_out
        if n > 0 && write(w.io, outbuf[1:n]) != n
            error("short write")
        end
        if w.strm.avail_out != 0
            break
        end
    end
    nb
end

# If this is not provided, Base.IO write methods will write
# arrays one element at a time.
function write{T}(w::Writer, a::Array{T})
    if isbits(T)
        write(w, pointer(a), length(a)*sizeof(T))
    else
        invoke(write, (IO, Array), w, a)
    end
end

# Copied from Julia base/io.jl
function write{T,N,A<:Array}(w::Writer, a::SubArray{T,N,A})
    if !isbits(T) || stride(a,1)!=1
        return invoke(write, (Any, AbstractArray), s, a)
    end
    colsz = size(a,1)*sizeof(T)
    if N<=1
        return write(s, pointer(a, 1), colsz)
    else
        cartesianmap((idxs...)->write(w, pointer(a, idxs), colsz),
                     tuple(1, size(a)[2:]...))
        return colsz*Base.trailingsize(a,2)
    end
end

function write(w::Writer, b::Uint8)
    write(w, Uint8[b])
end

function close(w::Writer)
    if w.closed
        return
    end
    w.closed = true

    # flush zlib buffer using Z_FINISH
    w.strm.next_in = Array(Uint8, 0)
    w.strm.avail_in = 0
    outbuf = Array(Uint8, 1024)
    ret = Z_OK
    while ret != Z_STREAM_END
        w.strm.avail_out = length(outbuf)
        w.strm.next_out = outbuf
        ret = ccall((:deflate, libz),
                    Int32, (Ptr{z_stream}, Int32),
                    &w.strm, Z_FINISH)
        if ret != Z_OK && ret != Z_STREAM_END
            error("Error in zlib deflate stream ($(ret)).")
        end
        n = length(outbuf) - w.strm.avail_out
        if n > 0 && write(w.io, outbuf[1:n]) != n
            error("short write")
        end
    end

    ret = ccall((:deflateEnd, libz), Int32, (Ptr{z_stream},), &w.strm)
    if ret == Z_STREAM_ERROR
        error("Error: zlib deflate stream was prematurely freed.")
    end
end

function compress(input::Vector{Uint8}, level::Integer, gzip::Bool=false, raw::Bool=false)
    b = IOBuffer()
    w = Writer(b, level, gzip, raw)
    write(w, input)
    close(w)
    takebuf_array(b)
end


function compress(input::String, level::Integer, gzip::Bool=false, raw::Bool=false)
    compress(convert(Vector{Uint8}, input), level, gzip, raw)
end


compress(input::Vector{Uint8}, gzip::Bool=false, raw::Bool=false) = compress(input, 9, gzip, raw)
compress(input::String, gzip::Bool=false, raw::Bool=false) = compress(input, 9, gzip, raw)


type Reader <: IO
    strm::z_stream
    io::IO
    buf::Vector{Uint8}
    closed::Bool

    Reader(strm::z_stream, io::IO, buf::Vector{Uint8}, closed::Bool) =
        (r = new(strm, io, buf, closed); finalizer(r, close); r)
end

function Reader(io::IO, raw::Bool=false)
    strm = z_stream()
    ret = ccall((:inflateInit2_, libz),
                Int32, (Ptr{z_stream}, Cint, Ptr{Uint8}, Int32),
                &strm, raw? -15 : 47, zlib_version(), sizeof(z_stream))
    if ret != Z_OK
        error("Error initializing zlib inflate stream.")
    end

    Reader(strm, io, Uint8[], false)
end

# Fill up the buffer with at least minlen bytes of uncompressed data,
# unless we have already reached EOF.
function fillbuf(r::Reader, minlen::Integer)
    ret = Z_OK
    while length(r.buf) < minlen && !eof(r.io) && ret != Z_STREAM_END
        input = read(r.io, Uint8, min(nb_available(r.io), 1024))
        r.strm.next_in = input
        r.strm.avail_in = length(input)
        r.strm.total_in = length(input)
        outbuf = Array(Uint8, 1024)

        while true
            r.strm.next_out = outbuf
            r.strm.avail_out = length(outbuf)
            ret = ccall((:inflate, libz),
                        Int32, (Ptr{z_stream}, Int32),
                        &r.strm, Z_NO_FLUSH)
            if ret == Z_DATA_ERROR
                error("Error: input is not zlib compressed data: $(bytestring(r.strm.msg))")
            elseif ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR
                error("Error in zlib inflate stream ($(ret)).")
            end
            if length(outbuf) - r.strm.avail_out > 0
                append!(r.buf, outbuf[1:(length(outbuf) - r.strm.avail_out)])
            end
            if r.strm.avail_out != 0
                break
            end
        end
    end
    length(r.buf)
end

function read{T}(r::Reader, a::Array{T})
    if isbits(T)
        nb = length(a)*sizeof(T)
        if fillbuf(r, nb) < nb
            throw(EOFError())
        end
        b = reinterpret(Uint8, reshape(a, length(a)))
        b[:] = r.buf[1:nb]
        r.buf = r.buf[nb+1:end]
    else
        invoke(read, (IO, Array), r, a)
    end
    a
end

# This function needs to be fast because readbytes, readall, etc.
# uses it. Avoid function calls when possible.
function read(r::Reader, ::Type{Uint8})
    if length(r.buf) < 1 && fillbuf(r, 1) < 1
        throw(EOFError())
    end
    b = r.buf[1]
    r.buf = r.buf[2:end]
    b
end

function close(r::Reader)
    if r.closed
        return
    end
    r.closed = true

    ret = ccall((:inflateEnd, libz), Int32, (Ptr{z_stream},), &r.strm)
    if ret == Z_STREAM_ERROR
        error("Error: zlib inflate stream was prematurely freed.")
    end
end

function eof(r::Reader)
    # Detecting EOF is somewhat tricky: we might not have reached
    # EOF in r.io but decompressing the remaining data might
    # yield no uncompressed data. So, make sure we can get at least
    # one more byte of decompressed data before we say we haven't
    # reached EOF yet.
    fillbuf(r, 1) == 0 && eof(r.io)
end

function decompress(input::Vector{Uint8}, raw::Bool=false)
    r = Reader(IOBuffer(input), raw)
    b = readbytes(r)
    close(r)
    b
end


decompress(input::String, raw::Bool=false) = decompress(convert(Vector{Uint8}, input), raw)


function crc32(data::Vector{Uint8}, crc::Integer=0)
    uint32(ccall((:crc32, libz),
                 Culong, (Culong, Ptr{Uint8}, Cuint),
                 crc, data, length(data)))
end

crc32(data::String, crc::Integer=0) = crc32(convert(Vector{Uint8}, data), crc)

end # module
