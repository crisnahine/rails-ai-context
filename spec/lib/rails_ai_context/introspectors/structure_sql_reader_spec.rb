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

  # Discourse's categories: the key list was cut at the first ")" and split
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

  it "keeps a serial key without a default when pg_dump sets its nextval by ALTER" do
    sql = <<~SQL
      CREATE TABLE public.users (
          id bigint NOT NULL,
          name character varying
      );
      ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);
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
end
