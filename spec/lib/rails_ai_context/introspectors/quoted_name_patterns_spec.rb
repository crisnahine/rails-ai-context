# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Ruby 3.1 has no regexp memoization, so a pattern that tries every start of a long run of quotes takes seconds there (the
# unanchored last-name pattern took 4 s for 16000 quotes). Each pattern the schema readers use on a quoted name stays linear.
RSpec.describe "patterns over a long run of quotes" do
  runs = [ '"' * 64_000, '"' * 64_000 + " x(", '"a""' * 16_000, '"' + "a" * 64_000, '"a".' * 16_000, "a." * 32_000 + '"' * 3, "`" * 64_000, "[" * 64_000 ]

  {
    "a virtual table column" => ->(text) { RailsAiContext::Introspectors::SchemaConventions::VIRTUAL_COLUMN.match(text) },
    "a part of a qualified name" => ->(text) { text.scan(RailsAiContext::SqlScan::QUALIFIED_PART) },
    "a domain's definition" => ->(text) { "CREATE DOMAIN #{text}".scan(/CREATE DOMAIN\s+#{RailsAiContext::Introspectors::StructureSqlReader::QUALIFIED_NAME}\s+AS\s+([^;]*);/im) },
    "a cast to a domain" => ->(text) { "'x'::#{text}"[/::(#{RailsAiContext::SqlScan::QUALIFIED_NAME_TEXT})\z/o, 1] },
    "a domain's column type" => ->(text) { text.match?(/\A#{RailsAiContext::Introspectors::StructureSqlReader::QUALIFIED_NAME}(?:\[\])?\z/o) },
    "the joined name" => ->(text) { RailsAiContext::SqlScan.split_qualified(text) }
  }.each do |name, scan|
    it "reads #{name} in linear time" do
      expect { Timeout.timeout(3) { runs.each { |text| scan.(text) } } }.not_to raise_error
    end
  end
end

# The same for text a dump holds between its words: a run of blanks, of parentheses, of array brackets, or an unclosed quote at a
# place a pattern searches without an anchor. Each template puts the fill where the reader splits or strips.
RSpec.describe "the readers over a long run of blanks, parentheses and quotes" do
  fills = {
    "blanks" => ->(n) { " " * n },
    "blanks then a word" => ->(n) { " " * n + "x" },
    "line breaks between blanks" => ->(n) { " \n" * (n / 2) },
    "open parentheses" => ->(n) { "(" * n },
    "spaced open parentheses" => ->(n) { " x(" * (n / 3) },
    "closing parentheses" => ->(n) { ") " * (n / 2) },
    "array brackets" => ->(n) { "[1]" * (n / 3) },
    "spaced array brackets" => ->(n) { " [1]" * (n / 4) },
    "an unclosed quote" => ->(n) { %("#{"a" * n}) },
    "quotes" => ->(n) { '"' * n },
    "commas" => ->(n) { "," * n },
    "WHERE keywords" => ->(n) { "WHERE (" * (n / 7) }
  }
  templates = {
    "a default clause" => ->(fill) { "CREATE TABLE public.t (a integer DEFAULT nextval('public.t_a_seq'::regclass)#{fill} NOT NULL);" },
    "a MySQL default clause" => ->(fill) { "CREATE TABLE `t` (\n  `a` int DEFAULT 1#{fill} COMMENT 'x',\n  PRIMARY KEY (`a`)\n) ENGINE=InnoDB;" },
    "an index's WHERE" => ->(fill) { "CREATE TABLE public.t (a integer);\nCREATE INDEX i ON public.t USING btree (a) #{fill};" },
    "a constraint added by ALTER" => ->(fill) { "CREATE TABLE public.t (a integer);\nALTER TABLE ONLY public.t ADD CONSTRAINT p#{fill} PRIMARY KEY (a);" },
    "a domain's type" => ->(fill) { "CREATE DOMAIN public.d AS integer#{fill};\nCREATE TABLE public.t (a public.d);" },
    "a domain's base before a clause" => ->(fill) { "CREATE DOMAIN public.d AS#{fill}integer NOT NULL;\nCREATE TABLE public.t (a public.d[]);" },
    "a column's type" => ->(fill) { "CREATE TABLE public.t (\n    a integer#{fill} NOT NULL\n);" },
    "a column's size" => ->(fill) { "CREATE TABLE public.t (\n    a numeric#{fill}(10,2)\n);" },
    "a column's array brackets" => ->(fill) { "CREATE TABLE public.t (\n    a integer#{fill}[]\n);" },
    "a MySQL column's modifier" => ->(fill) { "CREATE TABLE `t` (\n  `a` int unsigned#{fill} NOT NULL\n) ENGINE=InnoDB;" },
    "the lines of a body" => ->(fill) { "CREATE TABLE public.t (\n    a integer,#{fill}\n    b integer\n);" },
    "the INHERITS list" => ->(fill) { "CREATE TABLE public.p (a integer);\nCREATE TABLE public.t (b integer)#{fill}INHERITS (public.p);" },
    "a view's select item" => ->(fill) { "CREATE TABLE public.t (a integer);\nCREATE VIEW public.v AS SELECT t.a#{fill} FROM public.t;" },
    "a view's cast" => ->(fill) { "CREATE TABLE public.t (a integer);\nCREATE VIEW public.v AS SELECT (t.a)::numeric#{fill} AS a FROM public.t;" },
    "a view's collation" => ->(fill) { "CREATE TABLE public.t (a text);\nCREATE VIEW public.v AS SELECT t.a COLLATE#{fill} AS a FROM public.t;" }
  }

  templates.each do |template, build|
    it "reads #{template} in linear time" do
      expect do
        Timeout.timeout(3) { fills.each_value { |fill| RailsAiContext::Introspectors::StructureSqlReader.parse(build.(fill.(32_000))) } }
      end.not_to raise_error
    end
  end
end
