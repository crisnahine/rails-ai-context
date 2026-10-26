# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SideEffects do
  def effects(source)
    described_class.of(source, [], models: Set["Order", "Billing::Invoice", "Session", "CacheEntry", "RedisSyncLog"], columns: Set["name", "state"])
  end

  it "names each database write a body makes" do
    expect(effects("order = Order.find(id)\norder.save!\nitem = Order.new\nitem.destroy\nOrder.create(params)"))
      .to eq([ "database write (create, destroy, save!)" ])
  end

  it "counts a bulk write, a column write and a counter bang as a database write" do
    source = "Order.where(old: true).update_all(state: 1)\nOrder.delete_all\nOrder.all.destroy_all\nrow = Order.first\nrow.update_columns(a: 1)\n" \
             "row.update_column(:a, 1)\nOrder.insert_all!(rows)\nOrder.upsert_all(rows)\nOrder.upsert(row)\n" \
             "row.increment!(:views)\nrow.decrement!(:views)\nrow.toggle!(:pinned)\nrow.touch\nrow.update_attribute(:a, 1)"
    expect(effects(source)).to eq([ "database write (decrement!, delete_all, destroy_all, increment!, insert_all!, toggle!, touch, " \
                                    "update_all, update_attribute, update_column, update_columns, upsert, upsert_all)" ])
    expect(effects("row = Order.first\nrow.increment(:views)\nrow.touched?")).to eq([])
  end

  it "counts a record's or a model's delete, and no delete on a file, an env var or a key" do
    expect(effects("record = Order.first\nrecord.delete\nOrder.delete(id)\nOrder.delete_all\nOrder.delete_by(state: 0)"))
      .to eq([ "database write (delete, delete_all, delete_by)" ])
    expect([ effects("Order.delete(\"5\")"), effects("Order.last.delete") ]).to all(eq([ "database write (delete)" ]))
    [ "File.delete(path)", "FileUtils.touch(path)", "Dir.delete(path)", "ENV.delete(\"KEY\")", "Pathname.new(path).delete",
      "Pathname(path).delete", "hash.delete(:key)", "params.delete \"page\"", "@cache.delete(:key)",
      "Rails.root.join(\"tmp\", \"x\").delete", "Pathname.new(Rails.root.join(\"x\")).delete", "::File.delete(path)",
      "params.delete(\"\#{k}\")", "opts.delete(:\"\#{k}\")", "ids.delete(id)", "@seen.delete(key)", "Rails.cache.delete(k)",
      "Shared.cache.delete(Categories::COUNTS_KEY)", "params[:user].delete(:password)", "Stripe::Customer.create(email: e)",
      "Tempfile.create(\"x\")", "@queue.delete(item)", "attrs.delete(key)", "comment.delete" ].each do |line|
      expect(effects(line)).to eq([]), line
    end
  end

  # The receiver and argument are the call's own, never text that sits beside it.
  it "counts a delete whose next character is a ternary's colon or a literal on the next line" do
    [ "ok ? Order.first.delete : skip", "Order.first.delete\n:done", "Order.first.delete\n\"done\"" ].each do |source|
      expect(effects(source)).to eq([ "database write (delete)" ]), source
    end
    expect(effects("# record.save!\nx = \"order.destroy\"\nupdate(attrs)\nsave")).to eq([])
  end

  it "counts a write through an association chain, a namespaced model and a block over records" do
    source = "Order.find(id).items.create(a: 1)\nBilling::Invoice.where(x: 1).update_all(y: 2)\nInvoice.find_each { |inv| inv.touch }\n" \
             "@order ||= Order.find(id)\n@order.destroy\nspare = cached || Order.new\nspare.save\n"
    expect(effects(source)).to eq([ "database write (create, destroy, save, touch, update_all)" ])
  end

  it "takes a value derived from a model for no record, and a call chain only through methods that return records" do
    [ "Order.column_names.delete(\"id\")", "Order.pluck(:id).delete(3)", "Order.first.name.delete(\"x\")", "Order.first.attributes.delete(\"x\")",
      "def run(order)\n  order.as_json.delete(\"x\")\nend", "Order.first.serializable_hash.delete(:a)", "Order.ids.delete(1)", "Order.first.to_h.delete(:a)" ].each do |line|
      expect(effects(line)).to eq([]), line
    end
    expect(effects("Order.where(state: 1).first.items.create(a: 1)")).to eq([ "database write (create)" ])
  end

  it "tracks the records a local holds per method" do
    source = "def a\n  x = Order.find(1)\nend\n\ndef b\n  x = {}\n  x.delete(:k)\nend\n"

    expect(effects(source)).to eq([])
    expect(effects("def a\n  x = Order.find(1)\n  x.update(a: 1)\nend\n\ndef b\n  x.delete(:k)\nend\n")).to eq([ "database write (update)" ])
  end

  it "counts an unambiguous persistence call on any receiver a Hash, Array, Set or String does not answer, and an ambiguous one only on a record" do
    %w[save save! destroy destroy! update! touch increment! decrement! toggle! delete_all destroy_all update_all insert_all upsert_all
       find_or_create_by first_or_create create_or_find_by].each do |name|
      expect(effects("thing.#{name}")).to eq([ "database write (#{name})" ]), name
    end
    expect(effects("subject.update_columns(a: 1)\nrecord.update_column(:a, 1)")).to eq([ "database write (update_column, update_columns)" ])
    expect(effects("user.update(a: 1)\nsettings.delete(:a)\nclient.create(a: 1)")).to eq([])
    expect(effects("FileUtils.touch(path)\nPathname.new(p).touch\nRails.root.join(\"x\").touch")).to eq([])
  end

  it "counts a class-level counter or timestamp write and a write through a connection, and not a read of raw SQL" do
    %w[touch_all update_counters increment_counter decrement_counter].each do |name|
      expect(effects("Order.#{name}(1)")).to eq([ "database write (#{name})" ]), name
    end
    expect(effects("ActiveRecord::Base.connection.execute(\"DELETE FROM x\")\nconnection.exec_update(sql)\nconn = Order.connection\nconn.exec_insert(sql)\nconnection.exec_delete(sql)"))
      .to eq([ "database write (exec_delete, exec_insert, exec_update, execute)" ])
    expect(effects("connection.insert(sql)\nconnection.update(sql)\nconnection.delete(sql)")).to eq([ "database write (delete, insert, update)" ])
    expect(effects("connection.execute(\"SELECT 1\")\nclient.execute(sql)\nclient.insert(row)")).to eq([])
  end

  it "takes Rails' own non-record objects and cache or Redis clients for no record, whatever they are called on" do
    [ "session.destroy", "cookies.delete(:a)", "flash.touch", "Rails.cache.increment!(:a)", "cache.save", "Shared.cache.touch", "REDIS.touch(:k)",
      "redis.destroy", "@redis.save", "$redis.touch", "page_cache.touch" ].each do |line|
      expect(effects(line)).to eq([]), line
    end
    expect(effects("sessions.destroy")).to eq([ "database write (destroy)" ])
  end

  it "lets a known record origin win over the framework-object names" do
    {
      "session = Session.find(1)\nsession.destroy" => "destroy",
      "def a(session)\n  session.destroy\nend" => "destroy",
      "cache_entry = CacheEntry.find(1)\ncache_entry.save" => "save",
      "CacheEntry.delete_all" => "delete_all",
      "RedisSyncLog.destroy_all" => "destroy_all",
      "Order.cached_totals.update_all(a: 1)" => "update_all",
      "def a(order)\n  order.cache_entries.destroy_all\nend" => "destroy_all",
      "Order.first.session.touch" => "touch"
    }.each do |source, write|
      expect(effects(source)).to eq([ "database write (#{write})" ]), source
    end
  end

  it "counts a write on a parameter named for a model, and none on one named for nothing" do
    expect(effects("def perform(order, invoice: nil)\n  order.update(a: 1)\n  invoice.delete\n  thing.create(a: 1)\nend"))
      .to eq([ "database write (delete, update)" ])
    expect(effects("def perform((a, b), order = nil)\n  a.update(a: 1)\nend")).to eq([])
  end

  it "reads a source with bytes that are not UTF-8 without raising" do
    source = "Order.first.save\nRails.logger.info(\"\xFF\")\n".dup.force_encoding(Encoding::UTF_8)

    expect(effects(source)).to eq([ "database write (save)", "logging" ])
  end

  it "takes a predicate or a bulk method for no write of its name" do
    expect(effects("return if record.destroyed?\nrecord.saved_changes\nrecord.update_attribute_names")).to eq([])
    expect(effects("o = Order.first\no.destroyed?\no.saved_changes")).to eq([])
  end

  it "counts a request a client sends to a path or URL, and no key a store reads" do
    expect(effects(%(client.get("/status")))).to eq([ "HTTP request" ])
    expect(effects(%(Faraday.new(url: base)))).to eq([ "HTTP request" ])
    expect(effects(%(Rails.cache.read("k")\nredis.get("key")))).to eq([])
  end

  it "counts a file the body writes, not one it reads" do
    expect(effects(%(File.open("data.csv") { |f| f.read }))).to eq([])
    expect(effects(%(File.open(path, "w") { |f| f << row }))).to eq([ "file write" ])
    expect(effects(%(File.write(path, body)))).to eq([ "file write" ])
    expect(effects(%(File.open(path, mode: "w") { |f| f << row }))).to eq([ "file write" ])
    expect(effects(%(File.open(path, "r+") { |f| f << row }))).to eq([ "file write" ])
  end

  it "lists mail, broadcasts, cache, transactions, logging and notifications" do
    source = <<~RUBY
      UserMailer.welcome(user).deliver_later
      broadcast_replace_to user
      Rails.cache.fetch("k") { 1 }
      Order.transaction { }
      Rails.logger.info("x")
      ActiveSupport::Notifications.instrument("x")
    RUBY

    expect(effects(source)).to eq([ "Turbo broadcast", "cache write", "email delivery", "logging", "notification", "transaction" ])
  end

  it "counts a job the body enqueues, through the app's own enqueue helper too, and not one a comment names" do
    helpers = [ { owner: "Jobs", method: "enqueue", job_arg: 0 } ]

    expect(described_class.of("RefreshWorker.perform_in(5.minutes)", helpers)).to eq([ "job enqueue" ])
    expect(described_class.of("Jobs.enqueue(:process_post)", helpers)).to eq([ "job enqueue" ])
    expect(described_class.of("# SyncJob.perform_later\nx = 1", helpers)).to eq([])
  end
end
