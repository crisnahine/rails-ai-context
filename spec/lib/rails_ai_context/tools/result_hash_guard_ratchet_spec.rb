# frozen_string_literal: true

require "spec_helper"

# The introspector result stays a plain hash this program, so every tool
# still hand-rolls "is this a usable section or an error hash?". A typed
# result object is staged behind the section-fetch seam, not built here.
# Until then this count only goes down: adding another hand-rolled guard is
# a red build, and the number drops as tools move onto the shared seam.
RSpec.describe "Hand-rolled result-hash guards" do
  CEILING = 68

  GUARD = /\.is_a\?\(Hash\)\s*&&\s*!\s*\w+\[:error\]|unless\s+\w+\.is_a\?\(Hash\)\s*&&\s*!/

  it "does not grow" do
    tools_dir = File.expand_path("../../../../../lib/rails_ai_context/tools", __FILE__)

    # SectionFetch is where the check is supposed to live.
    counts = (Dir.glob(File.join(tools_dir, "*.rb")) - [ File.join(tools_dir, "section_fetch.rb") ]).to_h { |file|
      hits = File.readlines(file).reject { |l| l.strip.start_with?("#") }.count { |l| l.match?(GUARD) }
      [ File.basename(file), hits ]
    }.reject { |_, n| n.zero? }

    total = counts.values.sum

    expect(total).to be <= CEILING,
      "Hand-rolled result-hash guards rose to #{total} (ceiling #{CEILING}). " \
      "Route the new section read through the shared seam instead.\n" \
      "#{counts.sort_by { |_, n| -n }.map { |f, n| "  #{f}: #{n}" }.join("\n")}"
  end
end
