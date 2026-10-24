# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::StructureSqlReader do
  def indexes_for(index_sql, table: "categories")
    sql = <<~SQL
      CREATE TABLE public.#{table} (
          id integer NOT NULL,
          parent_category_id integer,
          name character varying,
          slug character varying,
          created_at timestamp without time zone
      );

      #{index_sql}
    SQL
    described_class.parse(sql)[:tables][table][:indexes]
  end

  it "reads an unlogged table and its index, which Rails lists as a table" do
    tables = described_class.parse(<<~SQL)[:tables]
      CREATE UNLOGGED TABLE public.cache_entries (
          id bigint NOT NULL,
          key character varying NOT NULL,
          value text
      );

      CREATE UNIQUE INDEX index_cache_entries_on_key ON public.cache_entries USING btree (key);
    SQL

    expect(tables["cache_entries"][:columns].map { |c| c[:name] }).to eq(%w[id key value])
    expect(tables["cache_entries"][:indexes]).to eq([ { name: "index_cache_entries_on_key", columns: [ "key" ], unique: true } ])
  end

  it "skips the bookkeeping tables and keeps one whose name only starts like them" do
    tables = described_class.parse(<<~SQL)[:tables]
      CREATE TABLE public.schema_migrations (version character varying NOT NULL);
      CREATE TABLE public.ar_internal_metadata (key character varying NOT NULL);
      CREATE TABLE public.schema_migrations_archive (version character varying NOT NULL);
    SQL

    expect(tables.keys).to eq([ "schema_migrations_archive" ])
  end

  # Rails reads a MySQL double as limit 53 and a PostgreSQL real as limit 24, and dumps a limit
  # that differs from the native float's (24 on MySQL, none on PostgreSQL).
  def float_limits(sql, rails_version: nil)
    described_class.parse(sql, rails_version: rails_version)[:tables]["items"][:columns].to_h { |c| [ c[:name], [ c[:type], c[:limit] ] ] }
  end

  it "gives a MySQL double limit 53 and a float none" do
    expect(float_limits(<<~SQL)).to include("price" => [ "float", 53 ], "ratio" => [ "float", nil ], "name" => [ "string", 100 ])
      CREATE TABLE `items` (
        `id` bigint NOT NULL AUTO_INCREMENT,
        `price` double NOT NULL,
        `ratio` float DEFAULT NULL,
        `name` varchar(100) DEFAULT NULL,
        PRIMARY KEY (`id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    SQL
  end

  # Booted Rails 7.0 and 8.1 on MySQL 8.4, and the schema.rb they dump: point matches the type map's /int/.
  it "types a MySQL type it does not name the way Rails' MySQL type map reads it" do
    sql = <<~SQL
      CREATE TABLE `w` (
        `id` bigint NOT NULL AUTO_INCREMENT,
        `a` point DEFAULT NULL,
        `b` multipoint DEFAULT NULL,
        `c` geometry DEFAULT NULL,
        `f` year DEFAULT NULL,
        `g` bit(1) DEFAULT NULL,
        `i` enum('a','print') DEFAULT NULL,
        `j` set('x','point') DEFAULT NULL,
        PRIMARY KEY (`id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    SQL
    columns = described_class.parse(sql)[:tables]["w"][:columns].to_h { |c| [ c[:name], c.slice(:type, :limit) ] }

    expect(columns).to eq(
      "id" => { type: "bigint" }, "a" => { type: "integer" }, "b" => { type: "integer" }, "c" => { type: nil },
      "f" => { type: "integer" }, "g" => { type: "binary", limit: 1 }, "i" => { type: "enum('a','print')" },
      "j" => { type: "set('x','point')" }
    )
  end

  # MySQL makes a bare bit a bit(1); booted Rails reads it as binary, limit 1.
  it "reads a bare MySQL bit as bit(1)" do
    columns = described_class.parse("CREATE TABLE `w` (`b` bit, `c` bit(8));", dialect: :mysql)[:tables]["w"][:columns].to_h { |c| [ c[:name], c.slice(:type, :limit) ] }

    expect(columns).to eq("b" => { type: "binary", limit: 1 }, "c" => { type: "binary", limit: 8 })
  end

  # mariadb-dump 11.4's lines; booted Rails 8.0 and 8.1 give these columns no type, since the MySQL type map has no uuid.
  it "types a MariaDB uuid the way Rails' MySQL type map reads it" do
    sql = <<~SQL
      CREATE TABLE `u` (
        `id` uuid NOT NULL,
        `a` uuid DEFAULT NULL,
        PRIMARY KEY (`id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    SQL
    columns = described_class.parse(sql, dialect: :mysql)[:tables]["u"][:columns].to_h { |c| [ c[:name], c[:type] ] }

    expect(columns).to eq("id" => nil, "a" => nil)
  end

  it "gives a PostgreSQL real limit 24 and a double precision none" do
    expect(float_limits(<<~SQL)).to include("score" => [ "float", 24 ], "total" => [ "float", nil ])
      CREATE TABLE public.items (
          id bigint NOT NULL,
          score real,
          total double precision
      );
    SQL
  end

  # PostgreSQL's array type delegates limit to its element (oid/array.rb), so a real[] reads as limit 24.
  it "gives a PostgreSQL real array the element's limit 24" do
    expect(float_limits(<<~SQL)).to include("scores" => [ "float", 24 ], "totals" => [ "float", nil ])
      CREATE TABLE public.items (
          id bigint NOT NULL,
          scores real[],
          totals double precision[]
      );
    SQL
  end

  it "gives a PostgreSQL real no limit before Rails 7.2.2, which first reads one" do
    expect(float_limits(<<~SQL, rails_version: "7.2.1")).to include("score" => [ "float", nil ])
      CREATE TABLE public.items (
          id bigint NOT NULL,
          score real
      );
    SQL
  end

  it "keeps a SQLite float's declared limit" do
    expect(float_limits(<<~SQL)).to include("score" => [ "float", 24 ], "total" => [ "float", nil ])
      CREATE TABLE IF NOT EXISTS "items" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "score" float(24), "total" float);
    SQL
  end

  # PostgreSQL reads a column whose nextval default names <table>_<column>_seq as a serial, whoever owns
  # the sequence, and the dump names it serial or bigserial; any other nextval stays the default.
  it "names a PostgreSQL serial as the dump does, from pg_dump's integer and sequence default" do
    long_table = "t" * 40
    long_column = "c" * 30
    tables = described_class.parse(<<~SQL)[:tables]
      CREATE TABLE public.keyed (id integer NOT NULL);
      CREATE TABLE public.small_keyed (id smallint NOT NULL);
      CREATE TABLE public.big_keyed (id bigint NOT NULL);
      CREATE TABLE public.counters (id bigint NOT NULL, s integer NOT NULL, ss smallint NOT NULL, b bigint NOT NULL);
      CREATE TABLE public.shared (
          id bigint DEFAULT nextval('public.shared_seq'::regclass) NOT NULL,
          n integer DEFAULT nextval('public.shared_seq'::regclass)
      );
      CREATE TABLE public.odd (id bigint NOT NULL, n integer DEFAULT nextval('public.odd_n_seq'::regclass));
      CREATE TABLE public.#{long_table} (#{long_column} integer NOT NULL);
      ALTER TABLE ONLY public.keyed ALTER COLUMN id SET DEFAULT nextval('public.keyed_id_seq'::regclass);
      ALTER TABLE ONLY public.small_keyed ALTER COLUMN id SET DEFAULT nextval('public.small_keyed_id_seq'::regclass);
      ALTER TABLE ONLY public.big_keyed ALTER COLUMN id SET DEFAULT nextval('public.big_keyed_id_seq'::regclass);
      ALTER TABLE ONLY public.counters ALTER COLUMN s SET DEFAULT nextval('public.counters_s_seq'::regclass);
      ALTER TABLE ONLY public.counters ALTER COLUMN ss SET DEFAULT nextval('public.counters_ss_seq'::regclass);
      ALTER TABLE ONLY public.counters ALTER COLUMN b SET DEFAULT nextval('public.counters_b_seq'::regclass);
      ALTER TABLE ONLY public.#{long_table} ALTER COLUMN #{long_column} SET DEFAULT nextval('public.#{"t" * 29}_#{"c" * 29}_seq'::regclass);
      ALTER TABLE ONLY public.keyed ADD CONSTRAINT keyed_pkey PRIMARY KEY (id);
      ALTER TABLE ONLY public.small_keyed ADD CONSTRAINT small_keyed_pkey PRIMARY KEY (id);
      ALTER TABLE ONLY public.big_keyed ADD CONSTRAINT big_keyed_pkey PRIMARY KEY (id);
      ALTER TABLE ONLY public.counters ADD CONSTRAINT counters_pkey PRIMARY KEY (id);
      ALTER TABLE ONLY public.shared ADD CONSTRAINT shared_pkey PRIMARY KEY (id);
    SQL
    shape = ->(name) { tables[name][:columns].to_h { |c| [ c[:name], c.slice(:type, :limit, :default).values ] } }
    nextval = %q(-> { "nextval('shared_seq'::regclass)" })

    expect([ shape.("keyed"), shape.("small_keyed"), shape.("big_keyed") ]).to eq(
      [ { "id" => [ "serial" ] }, { "id" => [ "serial", 2 ] }, { "id" => [ "bigint" ] } ]
    )
    expect(shape.("counters")).to eq("id" => [ "bigint" ], "s" => [ "serial" ], "ss" => [ "serial", 2 ], "b" => [ "bigserial" ])
    expect(shape.("shared")).to eq("id" => [ "bigint", nextval ], "n" => [ "integer", nextval ])
    expect(shape.("odd")).to eq("id" => [ "bigint" ], "n" => [ "serial" ])
    expect(shape.(long_table)).to eq(long_column => [ "serial" ])
  end

  # Only a single-column key is the default key (default_primary_key?); a composite key's columns dump as columns.
  it "names a bigserial in a composite key as the dump does" do
    tables = described_class.parse(<<~SQL)[:tables]
      CREATE TABLE public.orders (shop_id bigint NOT NULL, id bigint NOT NULL);
      CREATE TABLE public.lines (shop_id bigint NOT NULL, id bigserial NOT NULL, PRIMARY KEY (shop_id, id));
      ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);
      ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (shop_id, id);
    SQL

    expect(%w[orders lines].map { |name| tables[name][:columns].map { |c| c[:type] } }).to eq([ %w[bigint bigserial] ] * 2)
  end

  # schema_precision: a datetime's 6 goes unsaid, any other given precision is written, 0 too.
  it "keeps a PostgreSQL time type's precision as the dump writes it" do
    tables = described_class.parse(<<~SQL)[:tables]
      SET search_path = public;
      CREATE TABLE public.stamps (
          a timestamp(3) with time zone, b timestamp(6) with time zone, c timestamp(0) with time zone,
          d timestamp(0) without time zone, e timestamp(6) without time zone, f time(0) without time zone
      );
    SQL

    expect(tables["stamps"][:columns].map { |c| c.values_at(:type, :precision) }).to eq(
      [ [ "timestamptz", 3 ], [ "timestamptz", 6 ], [ "timestamptz", 0 ], [ "datetime", 0 ], [ "datetime", nil ], [ "time", 0 ] ]
    )
  end

  # The child's id takes the parent's sequence, which its own name does not make, so Rails reads an integer.
  it "reads an INHERITS child's copy of a serial as an integer with the parent's sequence" do
    tables = described_class.parse(<<~SQL)[:tables]
      CREATE TABLE public.parents (id integer NOT NULL, name character varying);
      CREATE TABLE public.children (extra integer)
      INHERITS (public.parents);
      ALTER TABLE ONLY public.children ALTER COLUMN id SET DEFAULT nextval('public.parents_id_seq'::regclass);
      ALTER TABLE ONLY public.parents ALTER COLUMN id SET DEFAULT nextval('public.parents_id_seq'::regclass);
      ALTER TABLE ONLY public.parents ADD CONSTRAINT parents_pkey PRIMARY KEY (id);
    SQL

    expect(tables["parents"][:columns].first.slice(:type, :default)).to eq(type: "serial")
    expect(tables["children"][:columns].first.slice(:type, :default, :null)).to eq(
      type: "integer", default: %q(-> { "nextval('parents_id_seq'::regclass)" }), null: false
    )
  end

  # A bigserial that is the whole key reads as the default bigint key, and its child still copies the sequence.
  it "gives an INHERITS child of a bigserial key the parent's sequence when no ALTER sets it" do
    tables = described_class.parse(<<~SQL, dialect: :postgresql)[:tables]
      CREATE TABLE parents (id bigserial PRIMARY KEY, name varchar);
      CREATE TABLE children (extra integer) INHERITS (parents);
    SQL

    expect(tables["parents"][:columns].first).to eq(name: "id", type: "bigint", null: false, primary_key: true)
    expect(tables["children"][:columns].first).to eq(name: "id", type: "bigint", null: false, default: %q(-> { "nextval('parents_id_seq'::regclass)" }))
  end

  # SQLite's type map takes an integer's limit from its parentheses alone, and only bigint is a bigint.
  it "sizes a SQLite integer by its parentheses, not its name" do
    expect(float_limits(<<~SQL)).to include("tiny" => [ "integer", 1 ], "small" => [ "integer", nil ], "eight" => [ "integer", nil ], "big" => [ "bigint", nil ])
      CREATE TABLE IF NOT EXISTS "items" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "tiny" integer(1), "small" smallint, "eight" int8, "big" bigint);
    SQL
  end

  # A categories index: the key list was cut at the first ")" and split
  # into words, so the expression read as four columns and `name` was lost.
  it "keeps an expression key whole and the column after it" do
    idx = indexes_for(<<~SQL).first
      CREATE UNIQUE INDEX unique_index_categories_on_name ON public.categories USING btree (COALESCE(parent_category_id, '-1'::integer), name);
    SQL

    expect(idx[:columns]).to eq([ "COALESCE(parent_category_id, '-1'::integer)", "name" ])
    expect(idx[:unique]).to be(true)
  end

  # A partial unique index constrains only the rows its WHERE picks, so
  # without the condition it read as unique over the whole table.
  it "keeps a partial index's expression key and its WHERE" do
    idx = indexes_for(<<~SQL).first
      CREATE UNIQUE INDEX unique_index_categories_on_slug ON public.categories USING btree (COALESCE(parent_category_id, '-1'::integer), lower((slug)::text)) WHERE ((slug)::text <> ''::text);
    SQL

    expect(idx[:columns]).to eq([ "COALESCE(parent_category_id, '-1'::integer)", "lower((slug)::text)" ])
    expect(idx[:where]).to eq("((slug)::text <> ''::text)")
  end

  it "gives an index with no WHERE no condition" do
    idx = indexes_for(<<~SQL).first
      CREATE INDEX index_categories_on_slug ON public.categories USING btree (slug) INCLUDE (name);
    SQL

    expect(idx).not_to have_key(:where)
  end

  it "drops the sort order and nulls placement from a column key" do
    idx = indexes_for(<<~SQL).first
      CREATE INDEX idx_created ON public.categories USING btree (created_at DESC, id DESC NULLS LAST);
    SQL

    expect(idx[:columns]).to eq(%w[created_at id])
  end

  it "drops an operator class from a column key" do
    idx = indexes_for(<<~SQL).first
      CREATE INDEX idx_name_trgm ON public.categories USING gin (name public.gin_trgm_ops);
    SQL

    expect(idx[:columns]).to eq(%w[name])
  end

  it "reads quoted keys the way sqlite dumps them" do
    idx = indexes_for(<<~SQL).first
      CREATE UNIQUE INDEX "index_categories_on_slug" ON "categories" ("slug", "parent_category_id");
    SQL

    expect(idx[:columns]).to eq(%w[slug parent_category_id])
  end

  it "still reads a plain key list" do
    idx = indexes_for("CREATE INDEX index_categories_on_name ON public.categories USING btree (name);").first

    expect(idx).to eq({ name: "index_categories_on_name", columns: %w[name], unique: false })
  end

  # MySQL keeps its keys in the CREATE TABLE body, with a prefix length.
  it "reads a MySQL key with a prefix length as its column" do
    sql = <<~SQL
      CREATE TABLE `posts` (
        `id` bigint NOT NULL AUTO_INCREMENT,
        `title` varchar(255) DEFAULT NULL,
        `user_id` bigint DEFAULT NULL,
        PRIMARY KEY (`id`),
        KEY `index_posts_on_title` (`title`(191),`user_id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    SQL

    idx = described_class.parse(sql)[:tables]["posts"][:indexes].first
    expect(idx[:columns]).to eq(%w[title user_id])
  end

  describe "index options" do
    it "reads the method, sort order, operator class and INCLUDE list as the schema.rb reader does" do
      gin, desc, ops, nulls = indexes_for(<<~SQL)
        CREATE INDEX index_categories_on_name ON public.categories USING gin (name);
        CREATE INDEX idx_parent ON public.categories USING btree (parent_category_id DESC, id DESC NULLS LAST) INCLUDE (name, slug);
        CREATE INDEX idx_trgm ON public.categories USING gin (slug public.gin_trgm_ops);
        CREATE UNIQUE INDEX idx_slug ON public.categories USING btree (slug) NULLS NOT DISTINCT WHERE (slug IS NOT NULL);
      SQL

      expect(gin).to include(using: "gin")
      expect(desc).to include(order: { "parent_category_id" => "desc", "id" => "DESC NULLS LAST" }, include: %w[name slug])
      expect(desc).not_to have_key(:using)
      expect(ops).to include(opclass: { "slug" => "gin_trgm_ops" })
      expect(nulls).to include(nulls_not_distinct: true, where: "(slug IS NOT NULL)")
    end

    it "reads a MySQL key's prefix lengths, order and method" do
      sql = <<~SQL
        CREATE TABLE `posts` (
          `id` bigint NOT NULL AUTO_INCREMENT,
          `title` varchar(255) DEFAULT NULL,
          `body` text,
          PRIMARY KEY (`id`),
          KEY `index_posts_on_title_body` (`title`(10),`body`(20)),
          UNIQUE KEY `uniq_desc` (`title` DESC) USING HASH
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      SQL

      lengths, desc = described_class.parse(sql)[:tables]["posts"][:indexes]
      expect(lengths).to include(columns: %w[title body], length: { "title" => 10, "body" => 20 })
      expect(desc).to include(order: { "title" => "desc" }, using: "hash")
    end

    # Booted MySQL 8.4 and MariaDB 11.4 on this table, and mysqldump's functional key.
    it "reads a MySQL key written without quotes or a name as an index MySQL names, never a column" do
      sql = <<~SQL
        CREATE TABLE u2 (id bigint PRIMARY KEY, a int, b int, c int, t text, INDEX (a), UNIQUE (a,b), KEY kb (b),
          INDEX ic USING BTREE (c), KEY (c DESC), FULLTEXT (t), FULLTEXT KEY ft2 (t), UNIQUE INDEX ub USING BTREE (b, c), INDEX ((a+1)));
        CREATE TABLE `u4` (
          `id` bigint NOT NULL,
          `a` int DEFAULT NULL,
          PRIMARY KEY (`id`),
          KEY `functional_index` (((`a` + 1)))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      SQL
      tables = described_class.parse(sql, dialect: :mysql)[:tables]
      indexes = tables["u2"][:indexes].to_h { |i| [ i[:name], i.slice(:columns, :unique, :type, :order) ] }

      expect(tables["u2"][:columns].map { |c| c[:name] }).to eq(%w[id a b c t])
      expect(indexes).to eq(
        "a" => { columns: %w[a], unique: false }, "a_2" => { columns: %w[a b], unique: true }, "kb" => { columns: %w[b], unique: false },
        "ic" => { columns: %w[c], unique: false }, "c" => { columns: %w[c], unique: false, order: { "c" => "desc" } },
        "t" => { columns: %w[t], unique: false, type: "fulltext" }, "ft2" => { columns: %w[t], unique: false, type: "fulltext" },
        "ub" => { columns: %w[b c], unique: true }, "functional_index" => { columns: [ "(a+1)" ], unique: false }
      )
      expect(tables["u4"][:indexes].map { |i| i.slice(:name, :columns) }).to eq([ { name: "functional_index", columns: [ "(`a` + 1)" ] } ])
    end

    it "keeps a PostgreSQL or SQLite column named key or index a column" do
      pg = described_class.parse("CREATE TABLE public.k (key character varying(20), index integer);", dialect: :postgresql)[:tables]["k"]
      sqlite = described_class.parse('CREATE TABLE "k" (key varchar(20), index integer);', dialect: :sqlite)[:tables]["k"]

      expect(pg[:columns].map { |c| c[:name] }).to eq(%w[key index])
      expect(sqlite[:columns].map { |c| c[:name] }).to eq(%w[key index])
      expect(pg[:indexes] + sqlite[:indexes]).to be_empty
    end
  end

  # sqlite3's .schema closes a view with a /* name(columns) */ comment of its own.
  it "ends a SQLite view's SQL before the column-list comment sqlite3 appends" do
    sql = <<~SQL
      CREATE TABLE IF NOT EXISTS "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "email" varchar);
      CREATE VIEW active_users AS SELECT id, email FROM users /*application='App'*/
      /* active_users(id,email) */;
      CREATE VIEW plain AS SELECT id FROM users;
    SQL

    views = described_class.parse(sql)[:views]
    expect(views["active_users"][:sql]).to eq("SELECT id, email FROM users /*application='App'*/")
    expect(views["plain"][:sql]).to eq("SELECT id FROM users")
  end

  describe "unique constraints" do
    it "reads pg_dump's ADD CONSTRAINT ... UNIQUE with its deferrable mode" do
      sql = <<~SQL
        CREATE TABLE public.accounts (id bigint NOT NULL, name character varying, code integer, slug text);
        ALTER TABLE ONLY public.accounts ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY public.accounts ADD CONSTRAINT uniq_name UNIQUE (name) DEFERRABLE;
        ALTER TABLE ONLY public.accounts
            ADD CONSTRAINT uniq_code UNIQUE (code, name) DEFERRABLE INITIALLY DEFERRED;
        ALTER TABLE ONLY public.accounts ADD CONSTRAINT uniq_slug UNIQUE (slug);
      SQL

      expect(described_class.parse(sql)[:tables]["accounts"][:unique_constraints]).to eq([
        { name: "uniq_name", columns: %w[name], deferrable: "immediate" },
        { name: "uniq_code", columns: %w[code name], deferrable: "deferred" },
        { name: "uniq_slug", columns: %w[slug] }
      ])
    end

    # IndexDefinition gains nulls_not_distinct in Rails 7.1; 7.0's dump has no such option.
    it "reads NULLS NOT DISTINCT on an index for Rails 7.1 on" do
      sql = <<~SQL
        CREATE TABLE public.a (id bigint NOT NULL, x integer);
        CREATE UNIQUE INDEX ix_x ON public.a USING btree (x) NULLS NOT DISTINCT;
      SQL
      index = ->(version) { described_class.parse(sql, rails_version: version)[:tables]["a"][:indexes].first }

      expect(index.("7.1.6")).to eq(name: "ix_x", columns: %w[x], unique: true, nulls_not_distinct: true)
      expect(index.("7.0.10")).to eq(name: "ix_x", columns: %w[x], unique: true)
    end

    # pg_dump 16's lines; Rails 8.0 dumps nulls_not_distinct: true on each, 7.2 leaves it out.
    it "reads NULLS NOT DISTINCT on a unique constraint for Rails 8.0 on" do
      sql = <<~SQL
        CREATE TABLE public.a (id bigint NOT NULL, x integer, y integer, z integer UNIQUE NULLS NOT DISTINCT);
        ALTER TABLE ONLY public.a ADD CONSTRAINT ux UNIQUE NULLS NOT DISTINCT (x, y) DEFERRABLE;
        ALTER TABLE ONLY public.a ADD CONSTRAINT uy UNIQUE NULLS DISTINCT (y);
      SQL
      uniques = ->(version) { described_class.parse(sql, rails_version: version)[:tables]["a"][:unique_constraints] }

      expect(uniques.("8.0.5")).to eq([
        { name: "a_z_key", columns: %w[z], nulls_not_distinct: true },
        { name: "ux", columns: %w[x y], deferrable: "immediate", nulls_not_distinct: true },
        { name: "uy", columns: %w[y] }
      ])
      expect(uniques.("7.2.4")).to eq([ { name: "a_z_key", columns: %w[z] }, { name: "ux", columns: %w[x y], deferrable: "immediate" }, { name: "uy", columns: %w[y] } ])
    end

    # Rails 7.0 has no unique_constraints, and its dump writes the index behind each (PostgreSQL 16 under 7.0.10).
    it "reads each as the unique index behind it for Rails 7.0" do
      sql = <<~SQL
        CREATE TABLE public.accounts (id bigint PRIMARY KEY, code integer UNIQUE, name character varying);
        ALTER TABLE ONLY public.accounts ADD CONSTRAINT uniq_name UNIQUE (name);
      SQL

      table = described_class.parse(sql, rails_version: "7.0.10")[:tables]["accounts"]
      expect(table[:indexes]).to eq([ { name: "accounts_code_key", columns: %w[code], unique: true }, { name: "uniq_name", columns: %w[name], unique: true } ])
      expect(table).not_to have_key(:unique_constraints)
    end
  end
  # The reader dropped every DEFAULT, so a structure.sql app showed no
  # [default: ...] hint at all. Defaults read the way the schema.rb reader
  # reports them: a literal's value, an expression as `-> { "expr" }`, and a
  # serial's nextval(...) as no default.
  describe "column defaults" do
    def columns_of(body, table: "posts")
      described_class.parse(body)[:tables][table][:columns].to_h { |c| [ c[:name], c ] }
    end

    let(:pg) do
      columns_of(<<~SQL)
        CREATE TABLE public.posts (
            id integer DEFAULT nextval('public.posts_id_seq'::regclass) NOT NULL,
            views integer DEFAULT 0 NOT NULL,
            score double precision DEFAULT 1.5,
            offset_days integer DEFAULT '-1'::integer,
            hidden boolean DEFAULT false NOT NULL,
            state character varying DEFAULT 'draft'::character varying NOT NULL,
            title character varying(255) DEFAULT ''::character varying,
            quote text DEFAULT 'it''s'::text,
            data jsonb DEFAULT '{}'::jsonb NOT NULL,
            list jsonb DEFAULT '[]'::jsonb,
            tag_ids integer[] DEFAULT '{}'::integer[] NOT NULL,
            names character varying[] DEFAULT '{a,"b c"}'::character varying[],
            nums bigint[] DEFAULT '{1,2}'::bigint[],
            created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
            seen_at timestamp with time zone DEFAULT now(),
            uuid uuid DEFAULT gen_random_uuid(),
            note text
        );
      SQL
    end

    it "reads literals as their value" do
      expect(pg.transform_values { |c| c[:default] }).to include(
        "views" => "0", "score" => "1.5", "offset_days" => "-1", "hidden" => "false",
        "state" => "draft", "title" => "", "quote" => "it's"
      )
    end

    it "reads json and array literals the way Rails dumps them" do
      expect(pg.transform_values { |c| c[:default] }).to include(
        "data" => "{}", "list" => "[]", "tag_ids" => "[]", "names" => '["a", "b c"]', "nums" => "[1, 2]"
      )
    end

    # pg_dump 16's lines; expected values are Rails 7.0.10 and 8.1.4's schema.rb for the same table. OID::Array casts
    # each element through the column's type: NULL is nil (a decimal's dumps as ""), a float 1 is 1.0.
    it "reads each array element through the column's type, as Rails dumps it" do
      columns = columns_of(<<~'SQL', table: "o3")
        CREATE TABLE public.o3 (
            i integer[] DEFAULT '{1,NULL,3}'::integer[],
            t text[] DEFAULT '{a,NULL,"NULL","b\\c","x\"y","p,q"," s "}'::text[],
            f double precision[] DEFAULT '{1,2.5}'::double precision[],
            n numeric[] DEFAULT '{1,2.5}'::numeric[],
            d numeric(5,2)[] DEFAULT '{2.555,10}'::numeric[],
            n0 numeric(5,0)[] DEFAULT '{1,2.5}'::numeric[],
            nn numeric[] DEFAULT '{1,NULL}'::numeric[],
            b boolean[] DEFAULT '{t,f,NULL}'::boolean[],
            ti time without time zone[] DEFAULT '{12:00:00}'::time without time zone[],
            nested integer[] DEFAULT '{{1,2},{3,4}}'::integer[],
            qe text[] DEFAULT '{"",abc}'::text[],
            nf double precision[] DEFAULT '{NULL,Infinity,NaN}'::double precision[]
        );
      SQL

      expect(columns.transform_values { |c| c[:default] }).to eq(
        "i" => "[1, nil, 3]", "t" => '["a", nil, "NULL", "b\\\\c", "x\\"y", "p,q", " s "]', "f" => "[1.0, 2.5]", "n" => '["1.0", "2.5"]',
        "d" => '["2.56", "10.0"]', "n0" => '["1", "2"]', "nn" => '["1.0", ""]', "b" => "[true, false, nil]",
        "ti" => '["2000-01-01 12:00:00"]', "nested" => "[[1, 2], [3, 4]]", "qe" => '["", "abc"]', "nf" => "[nil, Infinity, NaN]"
      )
    end

    # pg_dump 16, mysqldump 8.4 and SQLite's lines for one table; Rails 7.0.10 and 8.1.4 dump the same defaults
    # from each. Decimal casts to the scale, and a scale of 0 to the whole part (DecimalWithoutScale); MySQL rounded its own.
    it "reads a decimal default as Rails casts it to the column's scale" do
      pg = described_class.parse(<<~SQL)[:tables]["d1"][:columns]
        CREATE TABLE public.d1 (
            a numeric(5,0) DEFAULT 2.5,
            b numeric(10,2) DEFAULT 2,
            c numeric(10,2) DEFAULT 2.555,
            d numeric(5,0) DEFAULT '-2.5'::numeric,
            e numeric DEFAULT 3,
            f numeric(10,2) DEFAULT 7.10
        );
      SQL
      my = described_class.parse(<<~SQL, dialect: :mysql)[:tables]["d1"][:columns]
        CREATE TABLE `d1` (
          `a` decimal(5,0) DEFAULT '3',
          `b` decimal(10,2) DEFAULT '2.00',
          `e` decimal(10,3) DEFAULT '3.000'
        ) ENGINE=InnoDB;
      SQL
      sqlite = described_class.parse("CREATE TABLE d1 (a decimal(5) DEFAULT 2.5, d decimal(5,0) DEFAULT '-2.5', e decimal DEFAULT 3);",
                                     dialect: :sqlite)[:tables]["d1"][:columns]
      defaults = ->(columns) { columns.to_h { |c| [ c[:name], c[:default] ] } }

      expect(defaults.(pg)).to eq("a" => "2", "b" => "2.0", "c" => "2.56", "d" => "-2", "e" => "3.0", "f" => "7.1")
      expect(defaults.(my)).to eq("a" => "3", "b" => "2.0", "e" => "3.0")
      expect(defaults.(sqlite)).to eq("a" => "2", "d" => "-2", "e" => "3.0")
    end

    it "reads an ARRAY[...] default to its end, its commas and NULL inside the brackets" do
      columns = columns_of(<<~SQL, table: "o3")
        CREATE TABLE public.o3 (
            v character varying[] DEFAULT ARRAY['a'::text, NULL::text] NOT NULL,
            w integer
        );
      SQL

      expect(columns["v"]).to include(null: false)
      expect(columns.keys).to eq(%w[v w])
    end

    # pg_dump 16's lines; Rails 7.0.10 and 8.1.4 dump no default for an expression has_default_function? rejects.
    it "reads an expression as a function default only where Rails' PostgreSQL adapter does" do
      columns = columns_of(<<~SQL, table: "d1")
        CREATE TABLE public.d1 (
            arr_text text[] DEFAULT ARRAY['a'::text, 'b'::text],
            arr_int integer[] DEFAULT ARRAY[1, 2],
            arr_empty text[] DEFAULT ARRAY[]::text[],
            concat text DEFAULT ('a'::text || 'b'::text),
            sum integer DEFAULT (1 + 1),
            ctime time without time zone DEFAULT CURRENT_TIME,
            lts timestamp without time zone DEFAULT LOCALTIMESTAMP,
            cuser text DEFAULT CURRENT_USER,
            case_e integer DEFAULT
        CASE
            WHEN true THEN 1
            ELSE 2
        END,
            ldate date DEFAULT CURRENT_DATE,
            nowd date DEFAULT (now())::date,
            nowi timestamp without time zone DEFAULT (now() + 'P1D'::interval),
            cuser_t text DEFAULT (CURRENT_USER)::text
        );
      SQL

      expect(columns.transform_values { |c| c[:default] }).to eq(
        "arr_text" => nil, "arr_int" => nil, "arr_empty" => nil, "concat" => nil, "sum" => nil, "ctime" => nil, "lts" => nil,
        "cuser" => nil, "case_e" => nil, "ldate" => '-> { "CURRENT_DATE" }', "nowd" => '-> { "(now())::date" }',
        "nowi" => %q(-> { "(now() + 'P1D'::interval)" }), "cuser_t" => '-> { "(CURRENT_USER)::text" }'
      )
    end

    it "reads an array column as its element type with the array flag, as schema.rb does" do
      expect(pg["names"]).to include(type: "string", array: true)
      expect(pg["tag_ids"]).to include(type: "integer", array: true)
      expect(pg["views"]).not_to have_key(:array)
    end

    it "reads an expression as a proc source" do
      expect(pg.transform_values { |c| c[:default] }).to include(
        "created_at" => '-> { "CURRENT_TIMESTAMP" }', "seen_at" => '-> { "now()" }', "uuid" => '-> { "gen_random_uuid()" }'
      )
    end

    it "gives a serial key and a column with no DEFAULT no default" do
      expect(pg["id"]).not_to have_key(:default)
      expect(pg["note"]).not_to have_key(:default)
    end

    it "still reads the type and nullability around the default" do
      expect(pg["state"]).to include(type: "string", null: false)
      expect(pg["created_at"]).to include(type: "datetime", null: false)
    end

    it "reads mysqldump's quoted defaults" do
      my = columns_of(<<~SQL)
        CREATE TABLE `posts` (
          `id` bigint NOT NULL AUTO_INCREMENT,
          `views` int NOT NULL DEFAULT '0',
          `hidden` tinyint(1) NOT NULL DEFAULT '0',
          `pinned` tinyint(1) DEFAULT '1',
          `state` varchar(255) DEFAULT 'draft',
          `title` varchar(255) NOT NULL DEFAULT '',
          `note` text,
          `body` varchar(255) DEFAULT NULL,
          `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
          `updated_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
          `uid` varchar(36) DEFAULT (uuid()),
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      SQL

      expect(my.transform_values { |c| c[:default] }).to include(
        "views" => "0", "hidden" => "false", "pinned" => "true", "state" => "draft", "title" => "",
        "created_at" => '-> { "CURRENT_TIMESTAMP(6)" }', "updated_at" => '-> { "CURRENT_TIMESTAMP" }',
        "uid" => '-> { "(uuid())" }'
      )
      expect(my["body"]).not_to have_key(:default)
      expect(my["note"]).not_to have_key(:default)
      expect(my["id"]).not_to have_key(:default)
    end
  end
  describe "composite foreign keys" do
    # The shape the schema.rb reader gives: the names, in order, on both sides.
    it "reads pg_dump's ADD CONSTRAINT over two columns" do
      sql = <<~SQL
        CREATE TABLE public.readings (
            id bigint NOT NULL,
            measurement_id bigint,
            measurement_recorded_on date
        );

        ALTER TABLE ONLY public.readings
            ADD CONSTRAINT fk_readings_measurements FOREIGN KEY (measurement_id, measurement_recorded_on) REFERENCES public.measurements(id, recorded_on);
      SQL

      expect(described_class.parse(sql)[:tables]["readings"][:foreign_keys]).to eq([
        { from_table: "readings", to_table: "measurements",
          column: %w[measurement_id measurement_recorded_on], primary_key: %w[id recorded_on] }
      ])
    end

    it "reads mysqldump's inline constraint over two columns" do
      sql = <<~SQL
        CREATE TABLE `readings` (
          `measurement_id` bigint DEFAULT NULL,
          `measurement_recorded_on` date DEFAULT NULL,
          CONSTRAINT `fk_rm` FOREIGN KEY (`measurement_id`, `measurement_recorded_on`) REFERENCES `measurements` (`id`, `recorded_on`)
        ) ENGINE=InnoDB;
      SQL

      fk = described_class.parse(sql)[:tables]["readings"][:foreign_keys].first
      expect(fk).to include(column: %w[measurement_id measurement_recorded_on], primary_key: %w[id recorded_on])
    end
  end

  describe "primary keys" do
    it "reads a composite key from its ADD CONSTRAINT" do
      sql = <<~SQL
        CREATE TABLE public.accounts_tags (
            account_id bigint NOT NULL,
            tag_id bigint NOT NULL
        );

        ALTER TABLE ONLY public.accounts_tags
            ADD CONSTRAINT accounts_tags_pkey PRIMARY KEY (tag_id, account_id);
      SQL

      expect(described_class.parse(sql)[:tables]["accounts_tags"][:primary_key]).to eq(%w[tag_id account_id])
    end

    # The shape connection.primary_key gives and the schema.rb reader keeps:
    # the name for one column, the names for a composite key.
    it "gives a one-column key as its name" do
      sql = <<~SQL
        CREATE TABLE public.posts (
            id bigint NOT NULL
        );

        ALTER TABLE ONLY public.posts
            ADD CONSTRAINT posts_pkey PRIMARY KEY (id);

        CREATE TABLE `tags` (
          `id` bigint NOT NULL,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB;
      SQL

      tables = described_class.parse(sql)[:tables]
      expect(tables.transform_values { |t| t[:primary_key] }).to eq("posts" => "id", "tags" => "id")
    end

    it "reads mysqldump's inline key" do
      sql = <<~SQL
        CREATE TABLE `accounts_tags` (
          `account_id` bigint NOT NULL,
          `tag_id` bigint NOT NULL,
          PRIMARY KEY (`tag_id`,`account_id`)
        ) ENGINE=InnoDB;
      SQL

      expect(described_class.parse(sql)[:tables]["accounts_tags"][:primary_key]).to eq(%w[tag_id account_id])
    end
  end

  # pg_dump writes each partition as its own CREATE TABLE and attaches it
  # later, so a partitioned table read as one table per partition.
  it "lists a partitioned table once, without its partitions" do
    sql = <<~SQL
      CREATE TABLE public.measurements (
          id bigint NOT NULL,
          recorded_on date NOT NULL
      )
      PARTITION BY RANGE (recorded_on);

      CREATE TABLE public.measurements_2026_01 (
          id bigint DEFAULT nextval('public.measurements_id_seq'::regclass) NOT NULL,
          recorded_on date NOT NULL
      );

      CREATE TABLE public.measurements_2026_02 (
          id bigint DEFAULT nextval('public.measurements_id_seq'::regclass) NOT NULL,
          recorded_on date NOT NULL
      )
      PARTITION BY RANGE (recorded_on);

      CREATE TABLE public.measurements_2026_02_a (
          id bigint DEFAULT nextval('public.measurements_id_seq'::regclass) NOT NULL,
          recorded_on date NOT NULL
      );

      CREATE TABLE public.posts (
          id bigint NOT NULL,
          title text
      );

      ALTER TABLE ONLY public.measurements ATTACH PARTITION public.measurements_2026_01 FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

      ALTER TABLE ONLY public.measurements ATTACH PARTITION public.measurements_2026_02 FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

      ALTER TABLE ONLY public.measurements_2026_02 ATTACH PARTITION public.measurements_2026_02_a FOR VALUES FROM ('2026-02-01') TO ('2026-02-15');
    SQL

    expect(described_class.parse(sql)[:tables].keys).to eq(%w[measurements posts])
  end

  # pg_dump quotes a name only where it has to.
  it "lists a partitioned table once when its partition's name is quoted" do
    sql = <<~SQL
      CREATE TABLE public."Events" (
          id bigint NOT NULL
      )
      PARTITION BY LIST (id);

      CREATE TABLE public."Events_1" (
          id bigint NOT NULL
      );

      ALTER TABLE ONLY public."Events" ATTACH PARTITION public."Events_1" FOR VALUES IN (1);
    SQL

    expect(described_class.parse(sql)[:tables].keys).to eq(%w[Events])
  end

  it "keeps a table named like the first word of a quoted partition" do
    sql = <<~SQL
      CREATE TABLE public."Mixed" (
          id bigint NOT NULL
      );

      ALTER TABLE ONLY public."Mixed Case" ATTACH PARTITION public."Mixed Case 1" FOR VALUES IN (1);
    SQL

    expect(described_class.parse(sql)[:tables].keys).to eq(%w[Mixed])
  end

  it "keeps a table named like the schema of a partition attached elsewhere" do
    sql = <<~SQL
      CREATE TABLE public.audit (
          id bigint NOT NULL
      );

      ALTER TABLE ONLY audit.events ATTACH PARTITION audit.events_2026 FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
    SQL

    expect(described_class.parse(sql)[:tables].keys).to eq(%w[audit])
  end

  # A staging table loaded in bulk and attached later is a table until then.
  it "keeps a table that a function body attaches" do
    sql = <<~SQL
      CREATE FUNCTION public.attach_staged_events() RETURNS void
          LANGUAGE plpgsql
          AS $$
      BEGIN
      ALTER TABLE events ATTACH PARTITION events_staging FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
      END
      $$;

      CREATE TABLE public.events_staging (
          id bigint NOT NULL
      );
    SQL

    expect(described_class.parse(sql)[:tables].keys).to eq(%w[events_staging])
  end

  describe "INHERITS" do
    def columns(sql, table)
      described_class.parse(sql)[:tables][table][:columns].map { |c| c.values_at(:name, :type, :null) }
    end

    it "puts the parent's columns first when CREATE TABLE and INHERITS share one line" do
      sql = <<~SQL
        CREATE TABLE public.base_logs (
            id bigint NOT NULL,
            msg text
        );
        CREATE TABLE public.child_logs (extra integer) INHERITS (public.base_logs);
      SQL

      expect(columns(sql, "child_logs")).to eq([ [ "id", "bigint", false ], [ "msg", "text", true ], [ "extra", "integer", true ] ])
    end

    # pg_dump 17 output, with each table's columns as the catalog orders them.
    let(:dump) do
      <<~SQL
        CREATE TABLE public.base_logs (
            id bigint NOT NULL,
            msg text
        );
        CREATE TABLE public.child_logs (
            extra integer
        )
        INHERITS (public.base_logs);
        CREATE TABLE public.grand (
            g integer
        )
        INHERITS (public.child_logs);
        CREATE TABLE public.multi (
            own integer
        )
        INHERITS (public.base_logs, public.tags);
        CREATE TABLE public.tags (
            tag text DEFAULT 'x'::text NOT NULL,
            msg text
        );
        CREATE TABLE public.redecl (
            msg text NOT NULL,
            extra2 integer
        )
        INHERITS (public.base_logs);
        CREATE TABLE public.empty_child (
        )
        INHERITS (public.base_logs);
        CREATE TABLE public.notnull_child (
            z integer
        )
        INHERITS (public.base_logs);
        ALTER TABLE ONLY public.notnull_child ALTER COLUMN msg SET NOT NULL;
        ALTER TABLE ONLY public.child_logs ALTER COLUMN msg SET DEFAULT 'child'::text;
        ALTER TABLE ONLY public.grand ALTER COLUMN msg SET DEFAULT 'child'::text;
        ALTER TABLE ONLY public.multi ALTER COLUMN tag SET DEFAULT 'x'::text;
      SQL
    end

    let(:tables) { described_class.parse(dump)[:tables] }

    def names(table) = tables[table][:columns].map { |c| c[:name] }

    it "resolves a chain, several parents left to right, and a parent written later" do
      expect(names("grand")).to eq(%w[id msg extra g])
      expect(names("multi")).to eq(%w[id msg tag own])
      expect(names("empty_child")).to eq(%w[id msg])
    end

    it "merges a redeclared column into the inherited slot" do
      expect(columns(dump, "redecl")).to eq([ [ "id", "bigint", false ], [ "msg", "text", false ], [ "extra2", "integer", true ] ])
    end

    it "carries NOT NULL and defaults over, and applies the child's own" do
      cols = ->(table) { tables[table][:columns].to_h { |c| [ c[:name], c ] } }
      expect(cols["multi"]["tag"]).to include(null: false, default: "x")
      expect(cols["notnull_child"]["msg"][:null]).to be(false)
      expect(cols["base_logs"]["msg"]).to eq(name: "msg", type: "text", null: true)
      expect(cols["child_logs"]["msg"][:default]).to eq("child")
      expect(cols["grand"]["msg"][:default]).to eq("child")
    end

    it "reads a parent in another schema or under a quoted name, and lists only the tables it listed before" do
      sql = <<~SQL
        CREATE TABLE audit.base (
            id bigint NOT NULL,
            note text
        );
        CREATE TABLE public."my base" (
            tag text
        );
        CREATE TABLE public.child (
            extra integer
        )
        INHERITS (audit.base, public."my base");
      SQL
      tables = described_class.parse(sql)[:tables]

      expect(tables.keys).to eq(%w[child])
      expect(tables["child"][:columns].map { |c| c[:name] }).to eq(%w[id note tag extra])
      expect(tables["child"]).not_to have_key(:inherits_unresolved)
    end

    it "names a parent the file does not hold" do
      sql = <<~SQL
        CREATE TABLE public.orphan (
            x integer
        )
        INHERITS (elsewhere.gone);
      SQL
      table = described_class.parse(sql)[:tables]["orphan"]

      expect(table[:columns].map { |c| c[:name] }).to eq(%w[x])
      expect(table[:inherits_unresolved]).to eq(%w[elsewhere.gone])
    end

    it "reads INHERITS in any case" do
      sql = <<~SQL
        CREATE TABLE public.base_logs (
            id bigint NOT NULL
        );
        CREATE TABLE public.child_logs (extra integer) inherits (public.base_logs);
      SQL

      expect(columns(sql, "child_logs")).to eq([ [ "id", "bigint", false ], [ "extra", "integer", true ] ])
    end

    it "reads an array default set by ALTER the way it reads one in the body" do
      sql = <<~SQL
        CREATE TABLE public.base (
            vals double precision[]
        );
        CREATE TABLE public.inline (
            vals double precision[] DEFAULT '{1.5,2}'::double precision[]
        );
        CREATE TABLE public.child (
        )
        INHERITS (public.base);
        ALTER TABLE ONLY public.child ALTER COLUMN vals SET DEFAULT '{1.5,2}'::double precision[];
      SQL
      tables = described_class.parse(sql)[:tables]

      expect(tables["child"][:columns]).to eq(tables["inline"][:columns])
    end
  end

  # pg_dump 16 of CREATE TABLE q1 AS SELECT 1, 'x'::text AS "my col", 2 AS "a""b"; Rails 8.1.4 dumps all three columns.
  it "reads a quoted column name that is no plain word" do
    sql = <<~SQL
      CREATE TABLE public.q1 (
          "?column?" integer,
          "my col" text,
          "a""b" integer
      );
      ALTER TABLE ONLY public.q1 ALTER COLUMN "?column?" SET DEFAULT 5;
    SQL

    expect(described_class.parse(sql)[:tables]["q1"][:columns].map { |c| c.values_at(:name, :type, :default) })
      .to eq([ [ "?column?", "integer", "5" ], [ "my col", "text", nil ], [ 'a"b', "integer", nil ] ])
  end

  it "keeps a serial key without a default when pg_dump sets its nextval by ALTER" do
    sql = <<~SQL
      CREATE TABLE public.users (
          id bigint NOT NULL,
          name character varying
      );
      ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);
      ALTER TABLE ONLY public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
    SQL

    expect(described_class.parse(sql)[:tables]["users"][:columns]).to eq([
      { name: "id", type: "bigint", null: false },
      { name: "name", type: "string", null: true }
    ])
  end

  describe "schema-qualified names in later statements" do
    it "gives a quoted public table its index, key and foreign key, and drops it as a partition" do
      sql = <<~SQL
        CREATE TABLE "public"."pq" (
            id bigint NOT NULL
        );
        CREATE TABLE "public"."p1" (
            id bigint NOT NULL
        );
        CREATE TABLE public.other (
            id bigint NOT NULL
        );
        ALTER TABLE ONLY "public"."pq" ADD CONSTRAINT pq_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY "public"."pq" ADD CONSTRAINT fk_other FOREIGN KEY (id) REFERENCES "public"."other"(id);
        CREATE INDEX index_pq_on_id ON "public"."pq" USING btree (id);
        ALTER TABLE ONLY public.events ATTACH PARTITION "public"."p1" FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
      SQL
      tables = described_class.parse(sql)[:tables]

      expect(tables.keys).to eq(%w[pq other])
      expect(tables["pq"][:primary_key]).to eq("id")
      expect(tables["pq"][:indexes].map { |i| i[:name] }).to eq(%w[index_pq_on_id])
      expect(tables["pq"][:foreign_keys].map { |fk| fk[:to_table] }).to eq(%w[other])
    end

    it "keeps another schema's index and key off a public table of the schema's name" do
      sql = <<~SQL
        CREATE TABLE public.audit (
            id bigint NOT NULL,
            user_id bigint
        );
        CREATE TABLE audit.users (
            id bigint NOT NULL
        );
        CREATE INDEX index_audit_users_on_id ON audit.users USING btree (id);
        ALTER TABLE ONLY audit.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
        ALTER TABLE ONLY public.audit ADD CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES audit.users(id);
      SQL
      audit = described_class.parse(sql)[:tables]["audit"]

      expect(audit[:indexes]).to eq([])
      expect(audit).not_to have_key(:primary_key)
      expect(audit[:foreign_keys].map { |fk| fk[:to_table] }).to eq(%w[audit.users])
    end
  end

  # What schema.rb writes for the same column: a size the type was given, less
  # the defaults the dumper leaves out.
  describe "a column's size, collation and a foreign key's actions" do
    def columns(sql, table)
      described_class.parse(sql)[:tables][table][:columns].to_h { |c| [ c[:name], c.except(:name, :type, :null) ] }
    end

    it "reads them from pg_dump" do
      sql = <<~SQL
        SET search_path = '';
        CREATE TABLE public.orders (
            id bigint NOT NULL,
            total numeric(10,2),
            whole numeric(8),
            code character varying(20),
            label character varying COLLATE pg_catalog."C",
            seen_at timestamp(3) without time zone,
            made_at timestamp(6) without time zone,
            account_id bigint
        );

        ALTER TABLE ONLY public.orders
            ADD CONSTRAINT fk_rails_1 FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON UPDATE RESTRICT ON DELETE CASCADE;
      SQL

      expect(columns(sql, "orders")).to eq(
        "id" => {}, "total" => { precision: 10, scale: 2 }, "whole" => { precision: 8, scale: 0 },
        "code" => { limit: 20 }, "label" => { collation: "C" }, "seen_at" => { precision: 3 }, "made_at" => {}, "account_id" => {}
      )
      expect(described_class.parse(sql)[:tables]["orders"][:foreign_keys].first).to include(on_delete: "cascade", on_update: "restrict")
    end

    it "reads pg_dump's DEFERRABLE and NOT VALID on a foreign key" do
      sql = <<~SQL
        CREATE TABLE public.orders (id bigint NOT NULL, account_id bigint, user_id bigint);
        ALTER TABLE ONLY public.orders
            ADD CONSTRAINT fk_rails_1 FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED NOT VALID;
        ALTER TABLE ONLY public.orders
            ADD CONSTRAINT fk_rails_2 FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;
      SQL

      deferred, immediate = described_class.parse(sql)[:tables]["orders"][:foreign_keys]
      expect(deferred).to include(on_delete: "nullify", deferrable: "deferred", validate: false)
      expect(immediate).to include(deferrable: "immediate")
      expect(immediate).not_to have_key(:validate)
    end

    it "reads them from mysqldump, where varchar(255) and datetime(6) are the defaults" do
      sql = <<~SQL
        CREATE TABLE `orders` (
          `id` bigint NOT NULL AUTO_INCREMENT,
          `total` decimal(10,2) DEFAULT NULL,
          `code` varchar(255) DEFAULT NULL,
          `name` varchar(120) COLLATE utf8mb4_bin NOT NULL,
          `made_at` datetime(6) NOT NULL,
          `seen_at` datetime(3) DEFAULT NULL,
          `views` int DEFAULT NULL,
          `account_id` bigint DEFAULT NULL,
          PRIMARY KEY (`id`),
          CONSTRAINT `fk_rails_1` FOREIGN KEY (`account_id`) REFERENCES `accounts` (`id`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      SQL

      expect(columns(sql, "orders")).to eq(
        "id" => {}, "total" => { precision: 10, scale: 2 }, "code" => {}, "name" => { limit: 120, collation: "utf8mb4_bin" },
        "made_at" => {}, "seen_at" => { precision: 3 }, "views" => {}, "account_id" => {}
      )
      expect(described_class.parse(sql)[:tables]["orders"][:foreign_keys].first).to include(on_delete: "nullify")
    end
  end

  describe "check constraints and generated columns" do
    it "reads pg_dump's inline CHECK and a stored generated column" do
      sql = <<~SQL
        CREATE TABLE public.users (
            id bigint NOT NULL,
            age integer,
            age_next integer GENERATED ALWAYS AS ((age + 1)) STORED,
            CONSTRAINT age_nonneg CHECK ((age >= 0))
        );
      SQL
      users = described_class.parse(sql)[:tables]["users"]

      expect(users[:columns].map { |c| c[:name] }).to eq(%w[id age age_next])
      expect(users[:columns].last).to include(type: "integer", generated: "(age + 1)", stored: true)
      expect(users[:check_constraints]).to eq([ { name: "age_nonneg", expression: "(age >= 0)" } ])
    end

    it "reads mysqldump's virtual column and an unnamed SQLite CHECK" do
      mysql = <<~SQL
        CREATE TABLE `users` (
          `age` int DEFAULT NULL,
          `age_next` int GENERATED ALWAYS AS ((`age` + 1)) VIRTUAL,
          CONSTRAINT `users_chk_1` CHECK ((`age` >= 0))
        ) ENGINE=InnoDB;
      SQL
      sqlite = <<~SQL
        CREATE TABLE "posts" ("title" varchar, CHECK (length(title) > 0));
      SQL

      expect(described_class.parse(mysql)[:tables]["users"][:columns].last).to include(generated: "(`age` + 1)", stored: false)
      expect(described_class.parse(mysql)[:tables]["users"][:check_constraints]).to eq([ { name: "users_chk_1", expression: "`age` >= 0" } ])
      expect(described_class.parse(sqlite)[:tables]["posts"][:check_constraints]).to eq([ { expression: "length(title) > 0" } ])
    end
    it "drops the parentheses MySQL wraps a CHECK in, as the booted MySQL adapter does" do
      mysql = <<~SQL
        CREATE TABLE `users` (
          `a` int DEFAULT NULL,
          `b` int DEFAULT NULL,
          CONSTRAINT `both` CHECK (((`a` > 0) and (`b` > 0))),
          CONSTRAINT `either` CHECK ((`a` > 0) or (`b` > 0))
        ) ENGINE=InnoDB;
      SQL

      expect(described_class.parse(mysql)[:tables]["users"][:check_constraints]).to eq([
        { name: "both", expression: "(`a` > 0) and (`b` > 0)" },
        { name: "either", expression: "(`a` > 0) or (`b` > 0)" }
      ])
    end
  end

  # Rails writes SQLite's foreign key clause across lines, and Rails 7.x writes
  # no semicolon when ignore_tables makes it dump through sqlite_master.
  describe "SQLite dumps" do
    # Booted Rails 8.0 on each declared type; schema.rb names a lowercase bigint one, and no type is nil.
    it "types each column the way Rails' SQLite type map reads it" do
      sql = <<~SQL
        CREATE TABLE "w" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "a" REAL, "b" NUM, "c", "d" NOT NULL DEFAULT 1, "e" number, "f" clob, "g" point, "h" nvarchar(9), "i" jsonb, "j" bool, "k" bytea, "l" uuid, "m" smalldatetime, "n" BIGINT, "o" bigint(8), "p" double precision, "q");
      SQL
      columns = described_class.parse(sql)[:tables]["w"][:columns].to_h { |c| [ c[:name], c[:type] ] }

      expect(columns).to eq(
        "id" => "integer", "a" => nil, "b" => nil, "c" => nil, "d" => nil, "e" => "decimal", "f" => "text", "g" => "integer",
        "h" => "string", "i" => "json", "j" => nil, "k" => nil, "l" => nil, "m" => "datetime", "n" => "integer", "o" => "bigint",
        "p" => "float", "q" => nil
      )
    end

    # Booted Rails 8.0 on this table: SQLite drops an expression's outer parentheses, and the adapter
    # reads a literal or number as its value, a function as an expression, anything else as no default.
    it "reads each default the way Rails' SQLite adapter does" do
      sql = <<~SQL
        CREATE TABLE "d" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "a" boolean DEFAULT 1, "b" boolean DEFAULT 0, "c" datetime DEFAULT (CURRENT_TIMESTAMP), "d" varchar DEFAULT (lower('X')), "e" integer DEFAULT ((1+2)), "f" text DEFAULT ('x'), "g" integer DEFAULT (-3), "h" text DEFAULT ('a' || 'b'), "i" boolean DEFAULT true, "j" text DEFAULT "dq", "k" real DEFAULT (2.5));
      SQL
      defaults = ->(version) { described_class.parse(sql, rails_version: version)[:tables]["d"][:columns].to_h { |c| [ c[:name], c[:default] ] } }

      expect(defaults.("8.0.5")).to eq(
        "id" => nil, "a" => "true", "b" => "false", "c" => '-> { "CURRENT_TIMESTAMP" }', "d" => %q(-> { "lower('X')" }), "e" => nil,
        "f" => "x", "g" => "-3", "h" => %q(-> { "'a' || 'b'" }), "i" => nil, "j" => "dq", "k" => "2.5"
      )
      # Booted Rails 7.0 reads the quoted ends of a || concatenation as one literal.
      expect(defaults.("7.0.10")["h"]).to eq("a' || 'b")
    end

    # Booted Rails on this table: 8.0 reads TRUE as no default, 8.1.0 to 8.1.3 read the uppercase words as text,
    # and 8.1.4 reads either case as a boolean, which a string column casts to "t" or "f".
    it "reads a TRUE or FALSE default the way the app's Rails reads it" do
      sql = <<~SQL
        CREATE TABLE "t" ("id" integer PRIMARY KEY NOT NULL, "a" boolean DEFAULT TRUE, "b" boolean DEFAULT FALSE, "c" boolean DEFAULT true, "d" boolean DEFAULT false, "e" varchar DEFAULT TRUE, "g" varchar DEFAULT false, "h" boolean DEFAULT (TRUE));
      SQL
      defaults = ->(version) { described_class.parse(sql, rails_version: version)[:tables]["t"][:columns].to_h { |c| [ c[:name], c[:default] ] }.except("id") }

      expect(defaults.("8.0.5")).to eq("a" => nil, "b" => nil, "c" => nil, "d" => nil, "e" => nil, "g" => nil, "h" => nil)
      expect(defaults.("8.1.3")).to eq("a" => "true", "b" => "false", "c" => nil, "d" => nil, "e" => "TRUE", "g" => nil, "h" => "true")
      expect(defaults.("8.1.4")).to eq("a" => "true", "b" => "false", "c" => "true", "d" => "false", "e" => "t", "g" => "f", "h" => "true")
    end

    # Rails 8.1.3 and 8.1.4's schema.rb for this table, the column's type casting the word: 8.1.4 cannot dump an integer,
    # a whole decimal or a datetime holding true, and dumps an integer holding false with no default.
    it "reads a TRUE or FALSE default on a number or time column as the column's type casts it" do
      sql = <<~SQL
        CREATE TABLE "t" ("i" integer DEFAULT TRUE, "j" bigint DEFAULT FALSE, "f" float DEFAULT FALSE, "g" float DEFAULT true, "d" decimal(5) DEFAULT TRUE, "e" decimal(5,2) DEFAULT TRUE, "n" numeric DEFAULT FALSE, "w" datetime DEFAULT TRUE);
      SQL
      defaults = ->(version) { described_class.parse(sql, rails_version: version)[:tables]["t"][:columns].to_h { |c| [ c[:name], c[:default] ] } }

      expect(defaults.("8.1.3")).to eq("i" => "0", "j" => "0", "f" => "0.0", "g" => nil, "d" => "0", "e" => "0.0", "n" => "0.0", "w" => nil)
      expect(defaults.("8.1.4")).to eq("i" => nil, "j" => nil, "f" => "0.0", "g" => "1.0", "d" => nil, "e" => "1.0", "n" => "0.0", "w" => nil)
    end

    # Rails 7.0.10, 8.0.5 and 8.1.4 dump this table alike: the boolean type casts a quoted word, false only for its false words.
    it "reads a quoted default on a boolean as Rails' boolean type casts it" do
      sql = <<~SQL
        CREATE TABLE "b" ("a" boolean DEFAULT 't', "b" boolean DEFAULT 'f', "c" boolean DEFAULT 'no', "d" boolean DEFAULT '', "e" boolean DEFAULT 2, "f" boolean DEFAULT 'off');
      SQL
      defaults = described_class.parse(sql, rails_version: "8.0.5")[:tables]["b"][:columns].to_h { |c| [ c[:name], c[:default] ] }

      expect(defaults).to eq("a" => "true", "b" => "false", "c" => "true", "d" => nil, "e" => "true", "f" => "false")
    end

    # Only the MySQL adapter's columns know unsigned.
    it "reads an UNSIGNED BIG INT as an integer with no unsigned mark" do
      column = described_class.parse('CREATE TABLE "w" ("id" integer PRIMARY KEY, "ui" UNSIGNED BIG INT);')[:tables]["w"][:columns].last

      expect(column).to eq(name: "ui", type: "integer", null: true)
    end

    # Booted Rails 8.0: PRAGMA table_info gives a key without NOT NULL notnull 0, so the column allows NULL.
    it "reads a primary key declared without NOT NULL as allowing NULL" do
      sql = <<~SQL
        CREATE TABLE "w" ("id" integer PRIMARY KEY, "v" varchar);
        CREATE TABLE "x" ("code" varchar PRIMARY KEY);
        CREATE TABLE "z" ("id" integer NOT NULL PRIMARY KEY);
      SQL
      nulls = described_class.parse(sql)[:tables].transform_values { |t| t[:columns].first[:null] }

      expect(nulls).to eq("w" => true, "x" => true, "z" => false)
    end

    it "reads a table whose foreign key spans lines, and leaves out sqlite_sequence" do
      sql = <<~SQL
        CREATE TABLE "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL);
        CREATE TABLE sqlite_sequence(name,seq);
        CREATE TABLE "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "email" varchar NOT NULL, "account_id" integer NOT NULL, CONSTRAINT "fk_rails_61ac11da2b"
        FOREIGN KEY ("account_id")
          REFERENCES "accounts" ("id")
        );
        CREATE TABLE "tags" ("name" varchar, "user_id" integer, CONSTRAINT "fk_rails_e689f6d0cc"
        FOREIGN KEY ("user_id")
          REFERENCES "users" ("id")
         ON DELETE CASCADE);
      SQL
      tables = described_class.parse(sql)[:tables]

      expect(tables.keys).to eq(%w[accounts users tags])
      expect(tables["users"][:columns].map { |c| c[:name] }).to eq(%w[id email account_id])
      expect(tables["tags"][:columns].map { |c| c[:name] }).to eq(%w[name user_id])
      expect(tables["users"][:foreign_keys]).to eq([ { from_table: "users", to_table: "accounts", column: "account_id", primary_key: "id" } ])
      expect(tables["tags"][:foreign_keys]).to eq([ { from_table: "tags", to_table: "users", column: "user_id", primary_key: "id", on_delete: "cascade" } ])
    end

    it "skips a CREATE TABLE that never closes and reads the tables after it" do
      sql = <<~SQL
        CREATE TABLE "broken" ("a" varchar, "b" varchar(
        CREATE TABLE "kept" ("x" varchar, "note" varchar DEFAULT 'it''s (fine)', "naïve" integer);
      SQL

      expect(described_class.parse(sql)[:tables]["kept"][:columns].map { |c| c[:name] }).to include("x", "note")
      expect(described_class.parse("")[:tables]).to eq({})
    end

    it "splits a one-line table with multibyte text where it should" do
      sql = <<~SQL
        CREATE TABLE "notes" ("title" varchar DEFAULT 'é, (ü)' NOT NULL, "note" text DEFAULT 'ñ', CHECK (length("title") > 0));
      SQL
      notes = described_class.parse(sql)[:tables]["notes"]

      expect(notes[:columns].map { |c| c.values_at(:name, :default, :null) }).to eq([ [ "title", "é, (ü)", false ], [ "note", "ñ", true ] ])
      expect(notes[:check_constraints]).to eq([ { expression: 'length("title") > 0' } ])
    end

    it "reads statements with no semicolon" do
      sql = <<~SQL
        CREATE TABLE "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL)
        CREATE TABLE "codes" ("code" varchar, "label" varchar)
        CREATE INDEX "index_codes_on_label" ON "codes" ("label")
        CREATE UNIQUE INDEX "index_codes_on_code" ON "codes" ("code") WHERE code IS NOT NULL
        CREATE TABLE "later" ("x" varchar)
      SQL
      tables = described_class.parse(sql)[:tables]

      expect(tables.keys).to eq(%w[accounts codes later])
      expect(tables["codes"][:columns].map { |c| c[:name] }).to eq(%w[code label])
      expect(tables["codes"][:indexes]).to eq([
        { name: "index_codes_on_label", columns: [ "label" ], unique: false },
        { name: "index_codes_on_code", columns: [ "code" ], unique: true, where: "code IS NOT NULL" }
      ])
    end
  end

  describe "a view in a dump with no semicolons" do
    it "reads each view up to the next statement or the end of the file" do
      sql = <<~SQL
        CREATE TABLE "codes" ("code" varchar, "label" varchar)
        CREATE VIEW "v" AS SELECT code FROM codes
        CREATE TABLE "z" ("a" varchar)
        CREATE VIEW "w" AS SELECT label
        FROM codes
      SQL
      parsed = described_class.parse(sql)

      expect(parsed[:tables].keys).to eq(%w[codes z])
      expect(described_class.parse(sql)[:views]).to eq("v" => { materialized: false, sql: "SELECT code FROM codes" },
                                               "w" => { materialized: false, sql: "SELECT label\nFROM codes" })
    end

    it "reads a semicolon-ended view whose lines start with words a statement also starts with" do
      sql = "CREATE VIEW recent_posts AS SELECT id,\n  comment,\n  set,\n  drop,\n  title\nFROM posts WHERE id > 10;\nCREATE TABLE z (a integer);\n"

      expect(described_class.parse(sql)[:views]).to eq("recent_posts" => { materialized: false, sql: "SELECT id,\n  comment,\n  set,\n  drop,\n  title\nFROM posts WHERE id > 10" })
    end

    it "still reads pg_dump's view whose SELECT starts the next line" do
      sql = "CREATE VIEW public.v AS\n SELECT posts.id\n   FROM public.posts;\n\nCREATE TABLE public.z (a integer);\n"

      expect(described_class.parse(sql)[:views]).to eq("v" => { materialized: false, sql: "SELECT posts.id\n   FROM public.posts" })
    end
  end

  # The same table gives the same types whichever schema_format the app dumps.
  describe "column types as schema.rb names them" do
    it "reads pg_dump's schema-qualified, zoned and sized types" do
      sql = <<~SQL
        SET search_path = '';
        CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
        CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;
        CREATE TYPE public.mood AS ENUM ('happy', 'sad');

        CREATE TABLE public.things (
            id bigint NOT NULL,
            attrs public.hstore,
            handle public.citext,
            mood public.mood DEFAULT 'happy'::public.mood NOT NULL,
            data jsonb,
            at timestamp with time zone,
            blob bytea,
            alarm time without time zone,
            age smallint,
            code character(3),
            ratio real
        );
        COMMENT ON TABLE public.things IS 'Everything';
        COMMENT ON COLUMN public.things.data IS 'Raw payload';
      SQL
      parsed = described_class.parse(sql)
      things = parsed[:tables]["things"]
      columns = things[:columns].to_h { |c| [ c[:name], c ] }

      expect(columns.transform_values { |c| c[:type] }).to eq(
        "id" => "bigint", "attrs" => "hstore", "handle" => "citext", "mood" => "enum", "data" => "jsonb",
        "at" => "timestamptz", "blob" => "binary", "alarm" => "time", "age" => "integer", "code" => "string", "ratio" => "float"
      )
      expect(columns["mood"]).to include(enum_type: "mood", default: "happy", null: false)
      expect(columns["age"]).to include(limit: 2)
      expect(columns["code"]).to include(limit: 3)
      expect(columns["data"]).to include(comment: "Raw payload")
      expect(things[:comment]).to eq("Everything")
      expect(parsed[:enums]).to eq([ { name: "mood", values: %w[happy sad] } ])
    end

    it "reads mysqldump's unsigned, small and timestamp types and its comments" do
      sql = <<~SQL
        CREATE TABLE `things` (
          `u` int unsigned DEFAULT NULL,
          `big` bigint unsigned NOT NULL,
          `tiny` tinyint DEFAULT NULL,
          `flag` tinyint(1) DEFAULT NULL,
          `medium` mediumint DEFAULT NULL,
          `at` timestamp NULL DEFAULT NULL,
          `made` datetime(6) NOT NULL,
          `note` varchar(255) DEFAULT NULL COMMENT 'Shown, it''s fine',
          `raw` varbinary(16) DEFAULT NULL,
          `body` mediumtext,
          `blob` longblob
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mixed bag';
      SQL
      things = described_class.parse(sql)[:tables]["things"]
      columns = things[:columns].to_h { |c| [ c[:name], c.except(:name, :null) ] }

      expect(columns).to eq(
        "u" => { type: "integer", unsigned: true }, "big" => { type: "bigint", unsigned: true },
        "tiny" => { type: "integer", limit: 1 }, "flag" => { type: "boolean" }, "medium" => { type: "integer", limit: 3 },
        "at" => { type: "timestamp" }, "made" => { type: "datetime" },
        "note" => { type: "string", comment: "Shown, it's fine" }, "raw" => { type: "binary", limit: 16 },
        "body" => { type: "text", size: "medium" }, "blob" => { type: "binary", size: "long" }
      )
      expect(things[:comment]).to eq("Mixed bag")
    end
  end

  it "reads mysqldump's FULLTEXT and SPATIAL keys as indexes, not columns" do
    sql = <<~SQL
      CREATE TABLE `posts` (
        `id` bigint NOT NULL AUTO_INCREMENT,
        `body` text,
        `spot` point NOT NULL /*!80003 SRID 0 */,
        PRIMARY KEY (`id`),
        SPATIAL KEY `index_posts_on_spot` (`spot`),
        FULLTEXT KEY `index_posts_on_body` (`body`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
    SQL
    posts = described_class.parse(sql)[:tables]["posts"]

    expect(posts[:columns].map { |c| c[:name] }).to eq(%w[id body spot])
    expect(posts[:indexes]).to contain_exactly(
      { name: "index_posts_on_spot", columns: [ "spot" ], unique: false, type: "spatial" },
      { name: "index_posts_on_body", columns: [ "body" ], unique: false, type: "fulltext" }
    )
  end

  it "scans a dump once for its tables and once for its virtual tables, and for schemas only on PostgreSQL" do
    sqlite = +"CREATE TABLE \"users\" (\"id\" integer);\nCREATE VIRTUAL TABLE docs USING fts5 (body);\n"
    pg = +"CREATE SCHEMA app;\nCREATE TABLE public.users (\n    id bigint NOT NULL\n);\n"
    [ sqlite, pg ].each { |content| allow(content).to receive(:scan).and_call_original }

    described_class.parse(sqlite)
    described_class.parse(pg, search_path: %w[app public])

    expect(sqlite).not_to have_received(:scan).with(described_class::CREATE_TABLE)
    expect(sqlite).to have_received(:scan).with(described_class::VIRTUAL_TABLE).once
    expect(sqlite).not_to have_received(:scan).with(described_class::CREATE_SCHEMA)
    expect(pg).to have_received(:scan).with(described_class::CREATE_SCHEMA).once
  end
end
