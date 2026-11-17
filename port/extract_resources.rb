#!/usr/bin/env ruby
# frozen_string_literal: true

# List what each component manifest in a module declares, as written: every
# container run, file, volume and cron job, with each attribute's source text.
# Also checksum the module's templates, static files and upgrade plans.
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
# items, so a change to one mount or port shows up as that one item. A list
# built by adding lists together is flattened, and a variable in it is kept as
# "$name" so the reader can look the variable up.
def value_of(expr, text)
  case expr
  when Puppet::Pops::Model::LiteralList
    expr.values.map { |item| source_of(item, text) }
  when Puppet::Pops::Model::ArithmeticExpression
    [value_of(expr.left_expr, text), value_of(expr.right_expr, text)].flatten
  when Puppet::Pops::Model::VariableExpression
    "$#{source_of(expr.expr, text)}"
  else
    source_of(expr, text)
  end
end

# Every list a manifest assigns to a variable, such as $volumes. A variable set
# in both branches of a condition gets one entry per assignment.
def list_assignments(program, text)
  found = Hash.new { |hash, key| hash[key] = [] }
  program._pcore_all_contents([]) do |node|
    next unless node.is_a?(Puppet::Pops::Model::AssignmentExpression)
    next unless node.left_expr.is_a?(Puppet::Pops::Model::VariableExpression)

    value = value_of(node.right_expr, text)
    found[source_of(node.left_expr.expr, text)] << value if value.is_a?(Array)
  end
  found.sort.to_h
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
  program = parser.parse_string(text, path)
  found = resources_in(program, text)
  # Variable assignments carry the paths and commands the resources refer to.
  variables = text.scan(/^\s*\$(\w+)\s*=\s*(['"][^'"\n]*['"])\s*$/).to_h
  out[File.basename(path, '.pp')] = {
    'variables' => variables.sort.to_h, 'lists' => list_assignments(program, text), 'resources' => found
  }
end
# A checksum of every template and static file. A template whose body changed
# but whose parameters did not would otherwise go unnoticed. The upgrade plans
# are included because a change there can mean a data migration.
require 'digest'
files = {}
%w[templates files data plans/upgrade.pp plans/upgrade].each do |part|
  root = File.join(module_dir, part)
  paths = File.file?(root) ? [root] : Dir.glob(File.join(root, '**', '*')).select { |f| File.file?(f) }
  paths.sort.each { |f| files[f.delete_prefix("#{module_dir}/")] = Digest::SHA256.file(f).hexdigest[0, 16] }
end
puts JSON.pretty_generate('components' => out, 'files' => files)
