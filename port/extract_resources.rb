#!/usr/bin/env ruby
# frozen_string_literal: true

# List what each component manifest in a module declares, as written: every
# container run, file, volume and cron job, with each attribute's source text.
# Nothing is compiled or evaluated, so variables stay as $names. That is the
# point: two versions of a manifest compare cleanly whatever data they are fed.
#
# usage: extract_resources.rb <module dir>
require 'json'
require 'puppet'
require 'puppet/pops'

module_dir = ARGV.fetch(0)
WANTED = /(::runtime::run|::runtime::volume|::logrotate_config)\z|\A(file|cron|package|docker::run)\z/

def source_of(expr, text)
  text.byteslice(expr.offset, expr.length).gsub(/\s+/, ' ').strip
end

# The source text of an attribute value. A literal list becomes a list of its
# items, so a change to one mount or port shows up as that one item.
def value_of(expr, text)
  if expr.is_a?(Puppet::Pops::Model::LiteralList)
    expr.values.map { |item| source_of(item, text) }
  else
    source_of(expr, text)
  end
end

def resources_in(program, text)
  found = {}
  visit = lambda do |node|
    return unless node.is_a?(Puppet::Pops::Model::ResourceExpression)

    type = source_of(node.type_name, text).downcase
    return unless type.match?(WANTED)

    node.bodies.each do |body|
      attrs = {}
      body.operations.each do |op|
        attrs[op.attribute_name] = value_of(op.value_expr, text) if op.is_a?(Puppet::Pops::Model::AttributeOperation)
      end
      found["#{type}[#{source_of(body.title, text)}]"] = attrs.sort.to_h
    end
  end
  # _pcore_all_contents walks every descendant, so no recursion is needed here.
  program._pcore_all_contents([]) { |node| visit.call(node) }
  found.sort.to_h
end

parser = Puppet::Pops::Parser::EvaluatingParser.new
out = {}
Dir.glob(File.join(module_dir, 'manifests', 'component', '*.pp')).sort.each do |path|
  text = File.read(path)
  found = resources_in(parser.parse_string(text, path), text)
  # Variable assignments carry the paths and commands the resources refer to.
  variables = text.scan(/^\s*\$(\w+)\s*=\s*(['"][^'"\n]*['"])\s*$/).to_h
  out[File.basename(path, '.pp')] = { 'variables' => variables.sort.to_h, 'resources' => found }
end
puts JSON.pretty_generate(out)
