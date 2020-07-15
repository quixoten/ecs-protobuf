#!/usr/bin/env ruby

require "json"
require "net/https"
require "set"
require "yaml"

class ProtobufDefinitionBuilder
  ROOT          = File.expand_path("..", __FILE__)
  URI_PREFIX    = "https://raw.githubusercontent.com/elastic/ecs"
  URI_SUFFIX    = "generated/ecs/ecs_flat.yml"
  CACHED_FIELDS = File.join(ROOT, "cached-fields.yml")
  PROTO_FILE    = File.join(ROOT, "elastic.proto")

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
    if args.length != 1 || %w[-h --help].include?(args[0])
      abort <<~USAGE.chop
        Usage: #{$0} <tag_name>

        tag_name: A git ref from https://github.com/elastic/ecs
                  Examples: v1.5.0, master, e2d5286, e2d52861811f0888f69308e06412268dd296f731
      USAGE
    end

    self.new(args.first)
  end

  attr_reader :flat_file
  attr_reader :tag_name

  def initialize(tag_name)
    @flat_file = "#{ROOT}/ecs_flat/#{tag_name}.yml"
    @tag_name  = tag_name
  end

  def download_ecs_flat
    uri       = URI.parse("#{URI_PREFIX}/#{tag_name}/#{URI_SUFFIX}")
    redirects = 10

    loop do
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        req = Net::HTTP::Get.new(uri)
        http.request(req) do |res|
          case res
          when  Net::HTTPOK
            return YAML.load(res.body)
          when Net::HTTPFound
            redirects -= 1
            uri = URI.parse(res["location"])
            abort "Too many redirects" if redirects == 0
          else
            abort "Failed to retrieve flat file from #{uri}: #{res.code} #{res.class}"
          end
        end
      end
    end
  end

  def sort_fields(fields)
    fields.keys.sort do |a_key, b_key|
      if fields[a_key]["scope"] == fields[b_key]["scope"]
        if fields[a_key]["tag"] && fields[b_key]["tag"]
          fields[a_key]["tag"] <=> fields[b_key]["tag"]
        else
          a_key <=> b_key
        end
      else
        a_key <=> b_key
      end
    end.inject({}) do |sorted, key|
      sorted[key] = fields[key]
      sorted
    end
  end

  def build_fields_from_ecs_flat(ecs_flat)
    # rename @timestamp to timestamp
    ecs_flat.delete("@timestamp").tap do |timestamp|
      timestamp["flat_name"] = timestamp["name"] = "timestamp"
      ecs_flat["timestamp"] = timestamp
    end

    cascading_fields = {}
    flat_fields      = {}

    # create all of the containers (protobuf messages) for our fields
    ecs_flat.each do |key, field|
      fields_pointer = cascading_fields
      segments       = key.split(".")

      1.upto(segments.size - 1) do |level|
        parent_key       = segments[0, level].join(".")
        parent_name      = segments[level - 1]
        parent_scope     = segments[0, level - 1].join(".")
        parent_type      = camelize(parent_name)
        parent_normalize = ecs_flat.dig(parent_key, "normalize") || []

        unless VALID_NORMALIZE_SETTINGS.include?(parent_normalize)
          abort("Don't know how to handle #{name}'s normalize setting: #{parent_normalize.inspect}")
        end

        parent_type = "repeated #{parent_type}" if parent_normalize == ["array"]

        flat_fields[parent_key] = fields_pointer[parent_key] ||= {
          "key"        => parent_key,
          "name"       => parent_name,
          "scope"      => parent_scope,
          "type"       => parent_type,
          "deprecated" => false,
          "fields"     => {},
        }
        fields_pointer = fields_pointer[parent_key]["fields"]
      end; nil
    end

    # add each field to its container (protobuf message)
    ecs_flat.each do |key, field|
      segments  = key.split(".")
      name      = segments.pop()
      scope     = segments.join(".")
      type      = FIELD_TYPE_TO_PROTOBUF_TYPE.fetch(field.fetch("type"))
      normalize = field.fetch("normalize", [])

      unless VALID_NORMALIZE_SETTINGS.include?(normalize)
        abort("Don't know how to handle #{name}'s normalize setting: #{normalize}")
      end

      next if flat_fields.key?(key)

      fields = flat_fields.dig(scope, "fields") || cascading_fields

      flat_fields[key] = fields[key] = {
        "key"        => key,
        "name"       => name,
        "scope"      => scope,
        "type"       => type,
        "deprecated" => false,
      }
    end

    cascading_fields
  end

  def load_cached_fields
    if File.exist?(CACHED_FIELDS)
      YAML.load_file(CACHED_FIELDS)
    else
      {}
    end
  end

  def write_cache(fields)
    File.open(CACHED_FIELDS, "w") do |f|
      f.write(YAML.dump(fields))
    end
  end

  def camelize(string)
    string.split("_").map(&:capitalize).join("")
  end

  def merge_new_fields_with_old_fields(new_fields, old_fields)
    group_by_scope = lambda do |fields, group|
      fields.each_value do |field|
        scope = field["scope"]
        group[scope] ||= {}
        group[scope][field["key"]] = field
        group_by_scope.call(field["fields"], group)
      end

      group
    end

    new_by_scope  = group_by_scope.call(new_fields, {})
    old_by_scope  = group_by_scope.call(old_fields, {})

    scopes = Set.new(new_by_scope.keys + old_by_scope.keys).sort

    scopes.each do |scope|
      scoped_new_fields = new_by_scope.fetch(scope, {})
      scoped_old_fields = old_by_scope.fetch(scope, {})
      next_tag = scoped_old_fields.size + 1

      scoped_new_fields.each_key do |key|
        new_field    = new_fields.fetch(key)
        old_field    = old_fields.fetch(key, nil)

        if old_field.nil?
          tag = next_tag
          next_tag += 1
        else
          new_type = new_field["type"]
          old_type = old_field["type"]
          type_mismatch = new_type != old_type
          valid_type_change = PROTOBUF_LEGAL_TYPE_CHANGES.fetch(old_type, []).include?(new_type)

          if type_mismatch && !valid_type_change
            old_key  = old_field["key"]
            new_name = "deprecated_#{old_field["name"]}_#{old_field["tag"]}"
            new_key  = "#{scope}.#{new_name}"
            new_fields[new_key] = old_field.update(
              "deprecated" => true,
              "key"        => new_key,
              "name"       => new_name,
              "tag"        => old_field["tag"],
            )
            tag = next_tag
            next_tag += 1
            puts "Cannot change #{old_key} from #{old_type} to #{new_type}. " + \
                 "The #{old_type} version will be renamed to #{new_key}"
          else
            tag = old_field["tag"]
          end
        end

        new_field["tag"] = tag
      end

      scoped_old_fields.each_key do |key|
        new_field = new_fields.fetch(key, nil)
        old_field = old_fields.fetch(key)

        if new_field.nil?
          new_fields[key] = old_field
          if !old_field["deprecated"]
            puts("marking #{key} as depreacted")
            old_field.update({"deprecated" => true})
          end
        end
      end
    end

    sort_fields(new_fields)
  end

  def write_proto(fields)
    common_schema = {}

    fields.each_key do |key|
      field  = fields[key]
      scope  = field["scope"]
      parent = common_schema

      unless scope == ""
        scope.split(".").each do |name|
          parent[name] ||= {}
          parent = parent[name]
        end
      end

      parent["_fields"] ||= []
      parent["_fields"].append(field)
    end

    File.open(PROTO_FILE, "w") do |f|
      f.write("syntax = \"proto3\";\n\n")
      f.write("package elastic;\n\n")
      write_proto_message(f, "CommonSchema", common_schema)

    end
  end

  def write_proto_message(f, message_name, message, indent=0)
    spaces = " " * indent * 2

    f.write("#{spaces}message #{message_name} {\n")

    message.each do |nested_key, nested_field|
      next if nested_key == "_fields"
      nested_name = camelize(nested_key)
      write_proto_message(f, nested_name, nested_field, indent + 1)
    end

    message.fetch("_fields", []).each do |field|
      f_name = field["name"]
      f_type = field["type"]
      f_tag  = field["tag"]
      f_deprecated = " [deprecated=true]" if field["deprecated"]

      f.write("#{spaces}  #{f_type} #{f_name} = #{f_tag}#{f_deprecated};\n")
    end

    f.write("#{spaces}}\n\n")
  end

  def run!
    ecs_flat      = download_ecs_flat()
    new_fields    = build_fields_from_ecs_flat(ecs_flat)
    old_fields    = load_cached_fields()
    merged_fields = merge_new_fields_with_old_fields(new_fields, old_fields)

    write_proto(merged_fields)
    write_cache(merged_fields)
  end
end

ProtobufDefinitionBuilder.from_cmdline_args(ARGV).run!
