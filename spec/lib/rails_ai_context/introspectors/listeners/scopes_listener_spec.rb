# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ScopesListener do
  it "detects simple scopes" do
    results = parse_and_dispatch("scope :active, -> { where(active: true) }")
    expect(results.size).to eq(1)
    expect(results.first[:name]).to eq("active")
  end

  it "detects scopes with parameters" do
    results = parse_and_dispatch("scope :by_role, ->(role) { where(role: role) }")
    expect(results.first[:name]).to eq("by_role")
  end

  it "detects multiple scopes" do
    source = <<~RUBY
      scope :active, -> { where(active: true) }
      scope :recent, -> { order(created_at: :desc) }
    RUBY
    results = parse_and_dispatch(source)
    expect(results.map { |s| s[:name] }).to contain_exactly("active", "recent")
  end

  it "includes confidence tag" do
    results = parse_and_dispatch("scope :active, -> { where(active: true) }")
    expect(results.first[:confidence]).to eq("[VERIFIED]").or eq("[INFERRED]")
  end

  it "includes line location" do
    results = parse_and_dispatch("scope :active, -> { where(active: true) }")
    expect(results.first[:location]).to eq(1)
  end

  # `lambda { }` is a call with a block, not a LambdaNode, so the body read
  # as empty and the scope as inferred.
  it "reads the body of a multi-line lambda scope" do
    results = parse_and_dispatch(<<~RUBY)
      scope :published, lambda {
        where(published: true)
          .where("published_at <= ?", Time.current)
      }
    RUBY

    expect(results.first[:body]).to eq(%(where(published: true).where("published_at <= ?", Time.current)))
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "reads the parameters of a lambda-call scope" do
    results = parse_and_dispatch("scope :by_role, lambda { |role| where(role: role) }")

    expect(results.first[:required_params]).to eq([ "role" ])
    expect(results.first[:body]).to eq("where(role: role)")
  end

  it "reads the body of a block-form scope" do
    results = parse_and_dispatch("scope :active do where(active: true) end")

    expect(results.first[:body]).to eq("where(active: true)")
  end

  # Folding a body onto one line puts whatever follows a comment behind the
  # `#`, and the entry still claimed to be verified.
  it "drops a comment inside the body before folding it onto one line" do
    results = parse_and_dispatch(<<~RUBY)
      scope :live, -> { where(published: true) # only published
        .order(:id) }
    RUBY

    expect(results.first[:body]).to eq("where(published: true).order(:id)")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "joins a string split by a backslash continuation with one space" do
    source = "scope :unbooked, -> {\n  where('availability = ' \\\n        'COALESCE(x, 0)')\n}"
    results = parse_and_dispatch(source)

    expect(results.first[:body]).to eq("where('availability = ' 'COALESCE(x, 0)')")
  end

  it "leaves no space in front of a leading-dot continuation" do
    results = parse_and_dispatch("scope :ordered, lambda { where(y: 2)\n  .order(:id) }")

    expect(results.first[:body]).to eq("where(y: 2).order(:id)")
  end

  # The walk is what hands a listener the comments, so the fix is only real
  # if it survives the seam every introspector goes through.
  it "drops the comment through the walk the introspectors use" do
    source = <<~RUBY
      scope :live, -> { where(published: true) # only published
        .order(:id) }
    RUBY

    walked = RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { scopes: described_class })[:scopes]

    expect(walked.first[:body]).to eq("where(published: true).order(:id)")
  end

  # `scope :x, CALLABLE do ... end` passes the body as the callable and the
  # block as an extension, so reporting the block reported the wrong code.
  it "leaves an extension block out of the body when the call passes a callable" do
    results = parse_and_dispatch("scope :recent, RecentQuery do\n  def label\n    \"recent\"\n  end\nend")

    expect(results.first[:body]).to be_nil
    expect(results.first[:confidence]).to eq("[INFERRED]")
  end

  # Folding every newline to a space ran two statements together, so the body
  # read as Ruby the file never wrote and still claimed to be verified.
  describe "a body of more than one statement" do
    it "separates the statements of OFN's not_ready_for_checkout" do
      results = parse_and_dispatch(<<~RUBY)
        scope :not_ready_for_checkout, lambda {
          ready_enterprises = Enterprise.default_scoped.ready_for_checkout.
            except(:select).
            select('DISTINCT enterprises.id')

          if ready_enterprises.any?
            where.not(enterprises: { id: ready_enterprises })
          else
            where(nil)
          end
        }
      RUBY

      expect(results.first[:body]).to eq(
        "ready_enterprises = Enterprise.default_scoped.ready_for_checkout.except(:select)." \
        "select('DISTINCT enterprises.id'); if ready_enterprises.any?; " \
        "where.not(enterprises: { id: ready_enterprises }); else where(nil); end"
      )
      expect(Prism.parse("lambda { #{results.first[:body]} }")).to be_success
    end

    it "separates the statements of Whitehall's due_for_publication" do
      results = parse_and_dispatch(<<~RUBY)
        scope :due_for_publication, ->(within_time = 0) {
          cutoff = Time.zone.now + within_time
          scheduled.where(arel_table[:scheduled_publication].lteq(cutoff))
        }
      RUBY

      expect(results.first[:body]).to eq(
        "cutoff = Time.zone.now + within_time; " \
        "scheduled.where(arel_table[:scheduled_publication].lteq(cutoff))"
      )
    end

    # A newline the lexer names NEWLINE still separates nothing where the next
    # line opens with a closing bracket.
    it "opens no statement in front of a closing bracket" do
      results = parse_and_dispatch(<<~RUBY)
        scope :editable_by_producers, ->(enterprises) {
          joins(
            :distributor, line_items: :supplier
          ).where(
            supplier: { id: enterprises }
          )
        }
      RUBY

      expect(results.first[:body]).to eq("joins( :distributor, line_items: :supplier ).where( supplier: { id: enterprises } )")
      expect(Prism.parse("lambda { #{results.first[:body]} }")).to be_success
    end

    it "keeps a case body's branches apart" do
      results = parse_and_dispatch(<<~RUBY)
        scope :by_state, lambda { |state|
          case state
          when :draft
            where(state: "draft")
          else
            all
          end
        }
      RUBY

      expect(results.first[:body]).to eq('case state; when :draft; where(state: "draft"); else all; end')
      expect(Prism.parse("lambda { #{results.first[:body]} }")).to be_success
    end

    # A heredoc's body exists only on its own lines, so there is no one line
    # to fold it onto: folding it produced an unterminated heredoc.
    it "leaves a body carrying a heredoc unfolded" do
      results = parse_and_dispatch(<<~RUBY)
        scope :tagged_with_all, lambda { |tag_ids|
          Array(tag_ids).map(&:to_i).reduce(self) do |result, id|
            result.where(<<~SQL.squish, tag_id: id)
              EXISTS(SELECT 1 FROM taggings WHERE tag_id = :tag_id)
            SQL
          end
        }
      RUBY

      expect(results.first[:body]).to include("\n")
      expect(Prism.parse("lambda { #{results.first[:body]} }")).to be_success
    end

    it "keeps the heredoc's body when the heredoc opens on the body's last line" do
      results = parse_and_dispatch(<<~RUBY)
        scope :with_parents, ->(ids) { where(<<~SQL, ids: ids) }
          id IN (:ids)
          OR id IN (SELECT parent_category_id FROM categories WHERE id IN (:ids))
        SQL
        scope :visible, -> { where(hidden: false) }
      RUBY

      body = results.find { |r| r[:name] == "with_parents" }[:body]
      expect(body).to start_with("where(<<~SQL, ids: ids)\n")
      expect(body).to include("OR id IN (SELECT parent_category_id")
      expect(body).not_to include("visible")
      expect(Prism.parse("lambda { #{body}\n}")).to be_success
    end
  end

  # Whitehall's authored_by passes SQL as a plain string written across
  # lines; the fold left the newlines inside it and the row ran on.
  it "respells a multi-line string literal on one line, as the same string" do
    results = parse_and_dispatch(<<~'RUBY')
      scope :authored_by, lambda { |user|
        where(
          "EXISTS (
            SELECT 1 FROM edition_authors
            WHERE user_id = ?
          )",
          user.id
        )
      }
    RUBY

    body = results.first[:body]
    expect(body).not_to include("\n")
    expect(body).to include('"EXISTS (\n      SELECT 1 FROM edition_authors')
    strings = []
    collect = ->(n) { n.is_a?(Prism::StringNode) ? strings << n.unescaped : n.compact_child_nodes.each(&collect) }
    collect.call(Prism.parse("lambda { #{body} }").value)
    expect(strings).to include("EXISTS (\n      SELECT 1 FROM edition_authors\n      WHERE user_id = ?\n    )")
  end

  it "respells a single-quoted multi-line literal so it still means the same string" do
    results = parse_and_dispatch("scope :x, -> { where('a\n  b') }")

    expect(results.first[:body]).to eq('where("a\n  b")')
  end
end
