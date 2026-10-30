# frozen_string_literal: true

# Specs delete their scratch files under spec/ but not always the folders made for them. The run removes
# the ones it created and left empty, in its own process only: a child forked without a block runs the suite hooks too.
module ScratchFolders
  OWNER = Process.pid

  def self.all
    Dir.glob(File.join(__dir__, "..", "**", "*/")).map { |folder| File.expand_path(folder) }
  end

  BEFORE_RUN = all.freeze
end

RSpec.configure do |config|
  config.after(:suite) do
    next unless Process.pid == ScratchFolders::OWNER

    (ScratchFolders.all - ScratchFolders::BEFORE_RUN).sort.reverse_each do |folder|
      Dir.rmdir(folder) if Dir.empty?(folder)
    rescue SystemCallError
      nil
    end
  end
end
