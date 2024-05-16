require "digest/sha256"

class Wax::Assets
  getter name_map = {} of String => CacheEntry

  @path : String
  @cache_duration : Time::Span

  def initialize(
    @path = "assets",
    cache_for @cache_duration = ENV.fetch("ASSET_CACHE_DURATION_SECONDS", "86400").to_f.seconds
  )
  end

  def []?(key : String)
    entry = name_map.fetch(key) do
      value = hash(key)
      name_map[key] = CacheEntry.new(value, expires_at: @cache_duration.from_now)
      File.copy "public/#{key}", "public/#{value}"
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
    source = "public/#{key}"
    hash = Digest::SHA256.new.file(source).hexfinal
    "#{File.dirname(source).lchop("public")}/#{File.basename(source).rchop(File.extname(source))}-#{hash}#{File.extname(source)}"
  end

  record CacheEntry,
    value : String,
    expires_at : Time
end
