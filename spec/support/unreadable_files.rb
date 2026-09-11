# frozen_string_literal: true

# An example that proves what the gem does with a file it cannot read makes
# the file unreadable with chmod. Root ignores the mode and reads it anyway,
# and CI containers often run as root, so a green run there would be a false
# one. Two specs already asked the question the right way, by testing the
# effect rather than the user; this is that check with one wording.
module UnreadableFiles
  def make_unreadable(path)
    File.chmod(0o000, path)
    skip "cannot make a file unreadable as this user" if File.readable?(path)
  end
end

RSpec.configure { |config| config.include UnreadableFiles }
