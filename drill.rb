require "json"
require "open3"
require "time"
require "fileutils"

ENV["PGHOST"] = "127.0.0.1"
ENV["PGUSER"] = "postgres"
PROD = { port: 55432, db: "pagila" }
TARGET = { port: 55433, db: "drill" }
DIR = __dir__
ROW_TOLERANCE = 0.05
MAX_DATA_AGE_HOURS = 26

def psql(t, sql)
  out, err, st = Open3.capture3("psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-p", t[:port].to_s, "-d", t[:db], "-c", sql)
  raise "psql failed: #{err}" unless st.success?
  out.strip
end

def json(t, sql) = JSON.parse(psql(t, "select coalesce(json_agg(x), '[]') from (#{sql}) x"))

def fingerprint(t)
  json(t, <<~SQL).map { _1["item"] }.sort
    select 'column ' || c.table_name || '.' || c.column_name || ' ' || c.data_type || ' null=' || c.is_nullable as item
      from information_schema.columns c
      join information_schema.tables tb using (table_schema, table_name)
     where c.table_schema = 'public' and tb.table_type = 'BASE TABLE'
    union all
    select 'index ' || indexdef from pg_indexes where schemaname = 'public'
    union all
    select 'constraint ' || conrelid::regclass || ' ' || pg_get_constraintdef(oid)
      from pg_constraint where connamespace = 'public'::regnamespace
  SQL
end

def row_counts(t)
  json(t, <<~SQL).to_h { [_1["t"], _1["n"]] }
    select c.relname as t,
           (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::bigint as n
      from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
  SQL
end

def newest_data(t)
  json(t, <<~SQL).to_h { [_1["col"], _1["newest"]] }
    select c.table_name || '.' || c.column_name as col,
           (xpath('/row/m/text()', query_to_xml(format('select max(%I) as m from public.%I', c.column_name, c.table_name), false, true, '')))[1]::text as newest
      from information_schema.columns c
      join information_schema.tables tb using (table_schema, table_name)
     where c.table_schema = 'public' and tb.table_type = 'BASE TABLE'
       and c.data_type in ('timestamp without time zone', 'timestamp with time zone', 'date')
       and c.column_name <> 'last_update'
  SQL
end

def broken_sequences(t)
  json(t, <<~SQL)
    select s.schemaname || '.' || s.sequencename as seq, coalesce(s.last_value, 0) as last_value,
           tbl.relname || '.' || att.attname as col,
           (xpath('/row/m/text()', query_to_xml(format('select coalesce(max(%I),0) as m from public.%I', att.attname, tbl.relname), false, true, '')))[1]::text::bigint as max_id
      from pg_sequences s
      join pg_class sc on sc.relname = s.sequencename and sc.relnamespace = s.schemaname::regnamespace
      join (
        -- serial/identity columns own their sequence
        select d.objid as seq_oid, d.refobjid as tbl_oid, d.refobjsubid as attnum
          from pg_depend d
         where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype in ('a', 'i')
        union
        -- plain DEFAULT nextval('seq') columns
        select d.refobjid, ad.adrelid, ad.adnum
          from pg_attrdef ad
          join pg_depend d on d.classid = 'pg_attrdef'::regclass and d.objid = ad.oid and d.refclassid = 'pg_class'::regclass
      ) link on link.seq_oid = sc.oid
      join pg_class tbl on tbl.oid = link.tbl_oid and tbl.relkind = 'r'
      join pg_attribute att on att.attrelid = tbl.oid and att.attnum = link.attnum
     where s.schemaname = 'public'
  SQL
    .select { _1["last_value"].to_i < _1["max_id"].to_i }
end

def amcheck_failures(t)
  psql(t, "create extension if not exists amcheck")
  idx = json(t, "select c.oid::regclass::text as i from pg_index x join pg_class c on c.oid = x.indexrelid join pg_am a on a.oid = c.relam where a.amname = 'btree' and c.relkind = 'i' and c.relnamespace = 'public'::regnamespace")
  fails = idx.filter_map do |r|
    psql(t, "select bt_index_check('#{r['i']}'::regclass, true)")
    nil
  rescue => e
    "#{r['i']}: #{e.message.lines.first.strip}"
  end
  [idx.size, fails]
end

def baseline
  { schema: fingerprint(PROD), rows: row_counts(PROD), newest: newest_data(PROD) }
end

def backup(path, *args)
  out, err, st = Open3.capture3("pg_dump", "-Fc", "-p", PROD[:port].to_s, "-d", PROD[:db], "-f", path, *args)
  raise "pg_dump failed: #{err}" unless st.success?
  path
end

def restore(dump, list: nil)
  system("dropdb", "-p", TARGET[:port].to_s, "--if-exists", TARGET[:db])
  system("createdb", "-p", TARGET[:port].to_s, TARGET[:db])
  args = ["pg_restore", "--exit-on-error", "--no-owner", "-p", TARGET[:port].to_s, "-d", TARGET[:db]]
  args += ["-L", list] if list
  t0 = Time.now
  _out, err, st = Open3.capture3(*args, dump)
  secs = Time.now - t0
  psql(TARGET, "analyze") if st.success?
  { ok: st.success?, error: err.lines.grep(/error/i).first&.strip, secs: secs }
end

def check(base, dump, list: nil)
  findings = []
  r = restore(dump, list: list)
  unless r[:ok]
    findings << ["CRITICAL", "restore", "pg_restore failed: #{r[:error]}"]
    return [findings, r]
  end

  got = fingerprint(TARGET)
  missing = base[:schema] - got
  findings << ["CRITICAL", "schema", "#{missing.size} objects missing, e.g. #{missing.first}"] if missing.any?

  rows = row_counts(TARGET)
  base[:rows].each do |tbl, n|
    m = rows[tbl]
    if m.nil? then next
    elsif n.positive? && m.zero?
      findings << ["CRITICAL", "rows", "#{tbl}: 0 rows restored, production has #{n}"]
    elsif n.positive? && (n - m).abs.to_f / n > ROW_TOLERANCE
      findings << ["WARNING", "rows", "#{tbl}: #{m} rows restored vs #{n} in production (#{((n - m).abs * 100.0 / n).round(1)}% off)"]
    end
  end

  newest_prod = base[:newest].values.compact.map { Time.parse(_1) }.max
  newest_rest = newest_data(TARGET).values.compact.map { Time.parse(_1) }.max
  if newest_prod && newest_rest
    lag_h = (newest_prod - newest_rest) / 3600.0
    findings << ["CRITICAL", "freshness", "newest restored data is #{lag_h.round(1)}h behind production (limit #{MAX_DATA_AGE_HOURS}h)"] if lag_h > MAX_DATA_AGE_HOURS
  end

  broken_sequences(TARGET).each do |s|
    findings << ["CRITICAL", "sequences", "#{s['seq']} at #{s['last_value']} but #{s['col']} max is #{s['max_id']} → next INSERT fails with duplicate key"]
  end

  n_idx, fails = amcheck_failures(TARGET)
  fails.each { findings << ["CRITICAL", "amcheck", _1] }
  r[:indexes_checked] = n_idx
  r[:size] = psql(TARGET, "select pg_size_pretty(pg_database_size(current_database()))")
  [findings, r]
end

def report(name, expect, findings, r)
  verdict = findings.any? { _1[0] == "CRITICAL" } ? "FAIL" : (findings.any? ? "WARN" : "PASS")
  correct = (expect == "PASS") == (verdict == "PASS")
  puts "\n=== #{name}  →  #{verdict}   (expected #{expect}: #{correct ? 'correct' : 'WRONG'})"
  puts "    restore #{r[:ok] ? 'ok' : 'failed'} in #{r[:secs].round(2)}s#{r[:size] ? ", #{r[:size]}, #{r[:indexes_checked]} indexes amchecked" : ''}"
  findings.first(4).each { |sev, chk, msg| puts "    [#{sev}] #{chk}: #{msg}" }
  puts "    … #{findings.size - 4} more" if findings.size > 4
  correct
end

FileUtils.mkdir_p(File.join(DIR, "dumps"))
d = ->(n) { File.join(DIR, "dumps", n) }
results = []

psql(PROD, "create table if not exists audit_log (id bigserial primary key, action text not null, created_at timestamptz not null default '2022-07-01')")
psql(PROD, "insert into audit_log (action) select 'seed' from generate_series(1, 1000) where not exists (select 1 from audit_log)")
psql(PROD, "analyze audit_log")
good = backup(d["good.dump"])
base = baseline
results << report("A healthy backup", "PASS", *check(base, good))

File.binwrite(d["truncated.dump"], File.binread(good)[0, (File.size(good) * 0.6).to_i])
results << report("B truncated backup file (upload cut off)", "FAIL", *check(base, d["truncated.dump"]))

backup(d["missing_table.dump"], "-T", "public.film_actor")
results << report("C table left out of backup config", "FAIL", *check(base, d["missing_table.dump"]))

backup(d["missing_new_table.dump"], "-T", "public.audit_log")
results << report("C2 new table missing, restore still succeeds", "FAIL", *check(base, d["missing_new_table.dump"]))

backup(d["no_data.dump"], "--exclude-table-data=public.payment_p2022_07")
results << report("D table data excluded (e.g. 'skip big tables')", "FAIL", *check(base, d["no_data.dump"]))

list = d["no_seq.list"]
toc, = Open3.capture2("pg_restore", "-l", good)
File.write(list, toc.lines.reject { _1.include?("SEQUENCE SET") }.join)
results << report("E sequence values not restored", "FAIL", *check(base, good, list: list))

stale = backup(d["stale.dump"])
psql(PROD, <<~SQL)
  insert into rental (rental_date, inventory_id, customer_id, staff_id)
  select now() - (g || ' minutes')::interval, 1 + g, 1 + g, 1 from generate_series(1, 50) g
SQL
psql(PROD, "analyze")
results << report("F stale backup (production kept writing)", "FAIL", *check(baseline, stale))
psql(PROD, "delete from rental where rental_date > now() - interval '1 day'")

puts "\n#{results.count(true)}/#{results.size} scenarios classified correctly"
