# frozen_string_literal: true

# Turn a module's Config object into plain data that can be written as JSON.
# Sensitive values are replaced with a marker, and Bolt targets with their names.
Puppet::Functions.create_function(:'snapshot::to_data') do
  dispatch :to_data do
    param 'Any', :value
  end

  def to_data(value)
    case value
    when Puppet::Pops::Types::PSensitiveType::Sensitive
      '<sensitive>'
    when Hash
      value.each_with_object({}) { |(k, v), out| out[k.to_s] = to_data(v) }
    when Array
      value.map { |v| to_data(v) }
    when String, Integer, Float, TrueClass, FalseClass, NilClass
      value
    when Symbol
      value == :undef ? nil : value.to_s
    else
      value.respond_to?(:name) ? value.name : value.to_s
    end
  end
end
