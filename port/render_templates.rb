#!/usr/bin/env ruby
# frozen_string_literal: true

# Render the module templates named in a render spec, with the fixed values it
# gives, and print them as JSON: { "<path in module>": "<rendered text>" }.
#
# usage: render_templates.rb <module dir> <spec.yaml>
require 'json'
require 'yaml'
require 'puppet'
require 'puppet_pal'

module_dir = File.expand_path(ARGV.fetch(0))
spec = YAML.safe_load(File.read(ARGV.fetch(1)))
module_name = File.basename(module_dir)

# The names of the parameters an EPP template declares. The template as a
# whole parses to one lambda. Lambdas inside it, such as an each block, are
# not parameters of the template.
def declared_parameters(path)
  program = Puppet::Pops::Parser::EvaluatingParser::EvaluatingEppParser.new.parse_file(path)
  body = program.respond_to?(:body) ? program.body : program
  body.is_a?(Puppet::Pops::Model::LambdaExpression) ? body.parameters.map(&:name) : []
end

def puppet_value(value)
  if value.is_a?(Hash) && value.keys == ['sensitive']
    Puppet::Pops::Types::PSensitiveType::Sensitive.new(value['sensitive'])
  else
    value
  end
end

Puppet.initialize_settings(['--confdir', '/dev/null', '--vardir', '/dev/null']) unless Puppet.settings.global_defaults_initialized?
out = {}
Puppet::Pal.in_tmp_environment('render', modulepath: [File.dirname(module_dir)], facts: {}) do |pal|
  pal.with_script_compiler do |compiler|
    (spec['templates'] || {}).each do |template, values|
      path = File.join(module_dir, template)
      abort "#{module_name}: #{template} is no longer in the module" unless File.file?(path)

      declared = declared_parameters(path)
      missing = declared - values.keys
      unless missing.empty?
        abort "#{module_name}: #{template} now takes #{missing.join(', ')}, which port/render/#{module_name}.yaml gives no value for"
      end
      params = values.slice(*declared).transform_values { |v| puppet_value(v) }
      # epp() addresses a module template as <module>/<path under templates/>.
      text = compiler.call_function('epp', "#{module_name}/#{template.delete_prefix('templates/')}", params)
      # A template given a Sensitive value returns a Sensitive result. The
      # values here are placeholders, so there is nothing to protect.
      text = text.unwrap if text.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive)
      out[template] = text
    end
  end
end
(spec['files'] || []).each do |file|
  path = File.join(module_dir, file)
  abort "#{module_name}: #{file} is no longer in the module" unless File.file?(path)
  out[file] = File.read(path)
end
puts JSON.pretty_generate(out.sort.to_h)
