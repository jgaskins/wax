require "digest/sha256"
require "http/server/handler"
require "file_utils"

class Wax::Assets
  include HTTP::Handler
  getter name_map = {} of String => CacheEntry
  getter content_cache = {} of String => CacheEntry

  @source : String
  @target : String
  @cache_duration : Time::Span

  def initialize(
    @source = "assets",
    @target = "public",
    cache_for @cache_duration = ENV.fetch("ASSET_CACHE_DURATION_SECONDS", "86400").to_f.seconds,
  )
    Dir["#{target}/**/*"].each do |path|
      # Eagerly evaluate all of the unfingerprinted files
      unless path.matches? /-[0-9a-f]{64}\./
        self[path.lchop(target)]?
      end
    end
  end

  def []?(key : String)
    entry = name_map.fetch(key) do
      value = hash(key)
      name_map[key] = CacheEntry.new(value, expires_at: @cache_duration.from_now)
      # We just created this, so we know it's fresh and we can just return it
      return value
    end

    if entry.expires_at < Time.utc
      name_map.delete key
      self[key]?
    else
      entry.value
    end
  end

  def hash(key : String)
    source = "#{@target}/#{key}"
    unless File.exists? source
      source = "#{@source}/#{key}"
    end
    hash = Digest::SHA256.new.file(source).hexfinal
    value = "#{File.dirname(source).lchop(@target).lchop(@source)}/#{File.basename(source).rchop(File.extname(source))}-#{hash}#{File.extname(source)}"
    target = "#{@target}/#{value}"

    FileUtils.mkdir_p File.dirname target
    File.copy source, target

    value
  end

  def call(context : HTTP::Server::Context) : Bool
    request = context.request
    file_path = "#{@target}/#{request.path}"

    if request.method == "GET" && File.exists?(file_path)
      context.response << content_cache
        .fetch(file_path) do
          content_cache[file_path] = CacheEntry.new(
            value: File.read(file_path),
            expires_at: @cache_duration.from_now,
          )
        end
        .value

      true
    else
      call_next context
      false
    end
  end

  record CacheEntry,
    value : String,
    expires_at : Time
end
