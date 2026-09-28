# frozen_string_literal: true

# Tool output is read by an agent, not by the app's users, so a number the gem
# prints must not follow the host app's locale. rails-i18n ships plenty of
# locales whose decimal separator is a comma; this stands one up.
module CommaSeparatorLocale
  LOCALE = :"rac-test-comma"

  # The test locale lives in its own backend, chained in front of the real one,
  # so restoring the original backend removes it without touching anything else.
  def with_comma_separator_locale
    previous = I18n.available_locales
    previous_backend = I18n.backend
    test_backend = I18n::Backend::Simple.new
    test_backend.store_translations(LOCALE, number: {
      format: { separator: ",", delimiter: "." },
      human: { storage_units: { format: "%n %u", units: { byte: "Oktett", kb: "Ko", mb: "Mo", gb: "Go", tb: "To" } } }
    })
    I18n.backend = I18n::Backend::Chain.new(test_backend, previous_backend)
    I18n.available_locales = previous + [ LOCALE ]
    I18n.with_locale(LOCALE) { yield }
  ensure
    I18n.available_locales = previous
    I18n.backend = previous_backend
  end
end

RSpec.configure { |config| config.include CommaSeparatorLocale }

# An app whose available locales leave out English, as a German-only app sets them.
module GermanOnlyLocales
  def with_german_only_locales
    previous_available = I18n.available_locales
    previous_locale = I18n.locale
    I18n.available_locales = [ :de ]
    I18n.locale = :de
    yield
  ensure
    I18n.available_locales = previous_available
    I18n.locale = previous_locale
  end
end

RSpec.configure { |config| config.include GermanOnlyLocales }
