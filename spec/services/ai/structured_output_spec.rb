require "rails_helper"

RSpec.describe Ai::StructuredOutput do
  let(:schema) do
    {
      "type" => "object", "additionalProperties" => false, "required" => %w[a list],
      "properties" => {
        "a"    => { "type" => "string", "maxLength" => 5 },
        "kind" => { "type" => "string", "enum" => %w[x y] },
        "list" => { "type" => "array", "maxItems" => 2, "items" => { "type" => "string" } }
      }
    }
  end

  it "parses and validates bare JSON" do
    result = described_class.parse('{"a":"hi","list":["q"]}', schema)
    expect(result).to be_ok
    expect(result.data).to eq({ "a" => "hi", "list" => [ "q" ] })
  end

  it "extracts JSON from markdown fences and prose" do
    expect(described_class.parse("```json\n{\"a\":\"hi\",\"list\":[]}\n```", schema)).to be_ok
    expect(described_class.parse('Sure! {"a":"hi","list":[]} hope that helps', schema)).to be_ok
  end

  it "reports non-JSON" do
    result = described_class.parse("no json here", schema)
    expect(result).not_to be_ok
    expect(result.parsed_json).to be false
  end

  it "reports schema violations" do
    result = described_class.parse('{"a":"toolong","kind":"z","list":[1,"b","c"],"extra":1}', schema)
    expect(result).not_to be_ok
    expect(result.errors.join("\n")).to include("longer than 5", "one of x, y", "more than 2 items",
                                                "expected string", "extra: is not allowed")
  end

  it "reports missing required keys" do
    expect(described_class.parse('{"a":"x"}', schema).errors).to include("$.list: is required")
  end

  it "strips unsupported keywords for the wire schema" do
    wire = described_class.wire_schema(schema)
    expect(wire.to_json).not_to include("maxLength", "maxItems")
    expect(wire["properties"]["kind"]["enum"]).to eq(%w[x y])
  end
end
