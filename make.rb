#!/usr/bin/env ruby

require "json"
require "net/https"
require "set"
require "yaml"

class ProtobufDefinitionBuilder
  ROOT = File.expand_path("..", __FILE__)
  URI_PREFIX = "https://raw.githubusercontent.com/elastic/ecs"
  URI_SUFFIX = "generated/ecs/ecs_flat.yml"
  CACHED_FIELDS = File.join(ROOT, "cached-fields.yml")

  FIELD_TYPE_TO_PROTOBUF_TYPE = {
    "binary"       => "string",
    "boolean"      => "bool",
    "byte"         => "int32",
    "date_nanos"   => "long",
    "date"         => "string",
    "double"       => "double",
    "float"        => "float",
    "geo_point"    => "string",
    "half_float"   => "float",
    "integer"      => "int32",
    "ip"           => "string",
    "keyword"      => "string",
    "long"         => "int64",
    "object"       => "map <string, string>",
    "scaled_float" => "double",
    "short"        => "int32",
    "text"         => "string",
  }


  PROTOBUF_LEGAL_TYPE_CHANGES = {
    "int32"   => ["int32", "uint32", "int64", "uint64", "bool"],
    "uint32"  => ["int32", "uint32", "int64", "uint64", "bool"],
    "int64"   => ["int32", "uint32", "int64", "uint64", "bool"],
    "uint64"  => ["int32", "uint32", "int64", "uint64", "bool"],
    "bool"    => ["int32", "uint32", "int64", "uint64", "bool"],
    "sint32"  => ["sint32", "sint64"],
    "sint64"  => ["sint32", "sint64"],
    "fixed32" => ["fixed32", "sfixed32"],
    "fixed64" => ["fixed64", "sfixed64"],
    "enum"    => ["enum", "int32", "uint32", "int64", "uint64"],
  }


  VALID_NORMALIZE_SETTINGS = [
    [],
    ["array"],
  ]

  def self.from_cmdline_args(args)
    if args.length != 1
      abort <<~USAGE.chop
        Usage: #{$0} <tag_name>

        tag_name: A git ref from https://github.com/elastic/ecs
                  Examples: v1.5.0, master, e2d5286, e2d52861811f0888f69308e06412268dd296f731
      USAGE
    end

    self.new(args.first)
  end

  attr_reader :flat_file
  attr_reader :host
  attr_reader :port
  attr_reader :tag_name
  attr_reader :uri

  def initialize(tag_name)
    @flat_file = "#{ROOT}/ecs_flat/#{tag_name}.yml"
    @tag_name  = tag_name
    @uri       = URI.parse("#{URI_PREFIX}/#{tag_name}/#{URI_SUFFIX}")
    @host      = @uri.host
    @prot      = @uri.port
  end

  def run!
    download_flat_file
    convert_flat_file_to_proto
  end

  def download_flat_file
    redirects = 10

    catch(:done) do
      loop do
        Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          req = Net::HTTP::Get.new(uri)
          http.request(req) do |res|
            case res
            when  Net::HTTPOK
              File.open(flat_file, "w") do |f|
                puts "downloading to #{f.path} ..."
                res.read_body do |chunk|
                  f.write(chunk)
                end
              end

              throw :done
            when Net::HTTPFound
              redirects -= 1
              puts res["location"]
              uri = URI.parse(res["location"])
              abort "Too many redirects" if redirects == 0
            else
              abort "Failed to list releases at #{uri}: #{res.code} #{res.class}"
            end
          end
        end
      end
    end
  end

  def convert_flat_file_to_proto
    ecs_flat        = YAML.load_file(flat_file)
    new_fields      = cascade_fields(build_fields_from(ecs_flat))
    old_fields      = load_cached_fields
    combined_fields = merge_new_fields_with_old_fields(new_fields, old_fields)
    cache_fields(combined_fields)
  end

  # return a new hash of fields sorted by depth, then by key
  def cascade_fields(fields)
    sorted_keys = fields.keys.sort do |a_key, b_key|
      a_segments = a_key.split(".")
      b_segments = b_key.split(".")
      a_scope    = fields[a_key]["scope"]
      b_scope    = fields[a_key]["scope"]
      index      = 0

      loop do
        a_segment = a_segments.shift
        b_segment = b_segments.shift

        if a_segment == b_segment
          if a_scope == b_key
            break 1
          elsif b_scope == a_key
            break -1
          end
        end

        if a_segments.empty? || b_segments.empty?
          break a_segment <=> b_segment
        elsif a_segments.empty?
          break -1
        elsif b_segments.empty?
          break 1
        elsif a_segment != b_segment
          break a_segment <=> b_segment
        end

        index += 1
      end
    end.inject({}) do |cascading_fields, key|
      cascading_fields[key] = Marshal.load(Marshal.dump(fields[key]))
      cascading_fields
    end
  end

  def build_fields_from(ecs_flat)
    ecs_flat = Marshal.load(Marshal.dump(ecs_flat))

    # rename @timestamp to timestamp
    ecs_flat.delete("@timestamp").tap do |timestamp|
      timestamp["flat_name"] = timestamp["name"] = "timestamp"
      ecs_flat["timestamp"] = timestamp
    end

    # remove parent fields. these will be inferred later
    ecs_flat.each_key do |key|
      segments = key.split(".")
      if segments.size > 1
        parent = segments[0..-2].join(".")
        ecs_flat.delete(parent) if ecs_flat.key?(parent)
      end
    end

    # build a hash of fields with protobuf types
    ecs_flat.keys.inject({}) do |built_fields, key|
      field     = ecs_flat.fetch(key)
      segments  = key.split(".")
      name      = segments.pop()
      scope     = segments.join(".")
      type      = FIELD_TYPE_TO_PROTOBUF_TYPE.fetch(field.fetch("type"))
      normalize = field.fetch("normalize")

      unless VALID_NORMALIZE_SETTINGS.include?(normalize)
        abort("Don't know how to handle #{name}'s normalize setting: #{normalize}")
      end

      while segments.any? do
        parent_key   = segments.join(".")
        parent_name  = segments.pop()
        parent_scope = segments.join(".")

        built_fields[parent_key] = {
          "key"        => parent_key,
          "name"       => parent_name,
          "scope"      => parent_scope,
          "type"       => camelize(parent_name),
          "deprecated" => false,
        }
      end

      type = "repeated #{type}" if normalize == ["array"]

      built_fields[key] ||= {
        "key"        => key,
        "name"       => name,
        "scope"      => scope,
        "type"       => type,
        "deprecated" => false,
      }

      if type.start_with?("repeated map")
        abort "repeated map is not a valid protobuf type for #{key}"
      end

      built_fields
    end
  end

  def load_cached_fields
    if File.exist?(CACHED_FIELDS)
      YAML.load_file(CACHED_FIELDS)
    else
      {}
    end
  end

  def cache_fields(fields)
    File.open(CACHED_FIELDS, "w") do |f|
      f.write(YAML.dump(fields))
    end
  end

  def camelize(string)
    string.split("_").map(&:capitalize).join("")
  end

  def merge_new_fields_with_old_fields(new_fields, old_fields)
    merged_fields = Marshal.load(Marshal.dump(new_fields))
    new_by_scope  = {}
    old_by_scope  = {}

    new_fields.each_value do |field|
      scope = field["scope"]
      new_by_scope[scope] ||= {}
      new_by_scope[scope][field["key"]] = field
    end

    old_fields.each_value do |field|
      scope = field["scope"]
      old_by_scope[scope] ||= {}
      old_by_scope[scope][field["key"]] = field
    end

    scopes = Set.new(new_by_scope.keys + old_by_scope.keys).sort

    scopes.each do |scope|
      scoped_new_fields = new_by_scope.fetch(scope, {})
      scoped_old_fields = old_by_scope.fetch(scope, {})
      next_tag = scoped_old_fields.size + 1

      scoped_new_fields.each_key do |key|
        merged_field = merged_fields.fetch(key)
        new_field    = new_fields.fetch(key)
        old_field    = old_fields.fetch(key, nil)

        if old_field.nil?
          tag = next_tag
          next_tag = next_tag + 1
        else
          new_type = new_field["type"]
          old_type = old_field["type"]
          type_mismatch = new_type != old_type
          valid_type_change = PROTOBUF_LEGAL_TYPE_CHANGES.fetch(old_type, []).include?(new_type)

          if type_mismatch && !valid_type_change
            old_key  = old_field["key"]
            new_name = "deprecated_#{old_field["name"]}_#{old_field["tag"]}"
            new_key  = "#{scope}.#{new_name}"
            merged_fields[new_key] = Marshal.load(Marshal.dump(old_field)).update(
              "deprecated" => true,
              "key"        => new_key,
              "name"       => new_name,
              "tag"        => next_tag,
            )
            tag = next_tag
            next_tag = next_tag + 1
            puts "Cannot change #{old_key} from #{old_type} to #{new_type}." + \
                 "The #{old_type} version will be renamed to #{new_key}"
          else
            tag = old_field["tag"]
          end
        end

        merged_field["tag"] = tag
      end

      scoped_old_fields.each_key do |key|
        new_field = new_fields.fetch(key, nil)
        old_field = old_fields.fetch(key)

        if new_field.nil?
          merged_field = Marshal.load(Marshal.dump(old_field))
          merged_fields[key] = merged_field
          if !merged_field["deprecated"]
            puts("marking #{key} as depreacted")
            merged_field.update({"deprecated" => true})
          end
        end
      end
    end

    merged_fields
  end
end

ProtobufDefinitionBuilder.from_cmdline_args(ARGV).run!
