require "json"
require "open3"
require "time"
require "fileutils"

ENV["PGHOST"] ||= "127.0.0.1"
ENV["PGUSER"] ||= "postgres"
PROD = { port: ENV.fetch("PROD_PORT", "55432"), db: ENV.fetch("DRILL_DB") }
TARGET = { port: ENV.fetch("TARGET_PORT", "55433"), db: "drill_target" }
ROW_TOLERANCE = 0.05
MAX_AGE_S = Integer(ENV.fetch("MAX_DATA_AGE_SECONDS", "30"))
STALE_SLEEP_S = MAX_AGE_S + 15
RESTORE_FLAGS = %w[--no-owner --no-privileges --no-tablespaces --exit-on-error]
DUMPS = File.join(Dir.pwd, "dumps")
USER_NS = "n.nspname not in ('pg_catalog','information_schema') and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'"

HELPERS = <<~SQL
  create function pg_temp.safe_count(t regclass) returns bigint language plpgsql as $f$
  declare r bigint; begin execute 'select count(*) from ' || t::text into r; return r;
  exception when others then return null; end $f$;
  create function pg_temp.safe_newest(t regclass, c name) returns text language plpgsql as $f$
  declare r text; begin
    execute format('select to_char(max(%I)::timestamptz at time zone ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS"Z"'') from %s where %I < now() + interval ''1 day'' and %I > ''-infinity''', c, t::text, c, c) into r;
    return r;
  exception when others then return null; end $f$;
  create function pg_temp.safe_amcheck(i regclass) returns text language plpgsql as $f$
  begin perform bt_index_check(i, true); return null;
  exception when others then return sqlstate || ' ' || sqlerrm; end $f$;
  create function pg_temp.safe_maxnum(t regclass, c name) returns numeric language plpgsql as $f$
  declare r numeric; begin execute format('select max(%I)::numeric from %s', c, t::text) into r; return r;
  exception when others then return null; end $f$;
SQL

def psql(t, sql, helpers: false)
  args = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "-p", t[:port], "-d", t[:db]]
  args += ["-c", HELPERS] if helpers
  out, err, st = Open3.capture3(*args, "-c", sql)
  raise err.lines.grep(/ERROR/).first.to_s.strip unless st.success?
  out.strip
end

def json(t, sql, helpers: false) = JSON.parse(psql(t, "select coalesce(json_agg(x), '[]') from (#{sql}) x", helpers: helpers))

def fingerprint(t)
  json(t, <<~SQL).map { _1["i"] }.sort
    select format('column %I.%I.%I %s notnull=%s', n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull) as i
      from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('r','p') and a.attnum > 0 and not a.attisdropped and #{USER_NS}
     union all
    select format('index %s', indexdef) from pg_indexes i join pg_namespace n on n.nspname = i.schemaname where #{USER_NS}
     union all
    select format('constraint %s %s %s', coalesce(nullif(k.conrelid, 0)::regclass::text, k.contypid::regtype::text), k.conname, pg_get_constraintdef(k.oid))
      from pg_constraint k join pg_namespace n on n.oid = k.connamespace
     where k.conparentid = 0 and #{USER_NS} -- partition clones are re-derived on restore under other names
     union all
    select format('%s %I.%I', case c.relkind when 'v' then 'view' when 'm' then 'matview' when 'S' then 'sequence' end, n.nspname, c.relname)
      from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('v','m','S') and #{USER_NS}
  SQL
end

def tables_sql = "select c.oid::regclass::text as t from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'r' and #{USER_NS}"

def row_counts(t)
  json(t, "select t, pg_temp.safe_count(t::regclass) as n from (#{tables_sql}) s", helpers: true).to_h { [_1["t"], _1["n"]] }
end

def newest(t)
  json(t, <<~SQL, helpers: true).map { _1["v"] }.compact.map { Time.parse(_1) }.max
    select pg_temp.safe_newest(c.oid::regclass, a.attname) as v
      from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r' and a.attnum > 0 and not a.attisdropped and #{USER_NS}
       and a.atttypid in ('timestamp'::regtype, 'timestamptz'::regtype, 'date'::regtype)
  SQL
end

def sequence_links(t)
  json(t, <<~SQL, helpers: true)
    select s.oid::regclass::text as seq, tbl.oid::regclass::text || '.' || att.attname as col,
           pg_sequence_last_value(s.oid) as last_value,
           pg_temp.safe_maxnum(tbl.oid::regclass, att.attname) as max_id
      from pg_class s
      join (
        select d.objid as seq_oid, d.refobjid as tbl_oid, d.refobjsubid as attnum
          from pg_depend d where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype in ('a','i')
        union
        select d.refobjid, ad.adrelid, ad.adnum
          from pg_attrdef ad join pg_depend d on d.classid = 'pg_attrdef'::regclass and d.objid = ad.oid and d.refclassid = 'pg_class'::regclass
      ) l on l.seq_oid = s.oid
      join pg_class tbl on tbl.oid = l.tbl_oid and tbl.relkind = 'r'
      join pg_attribute att on att.attrelid = tbl.oid and att.attnum = l.attnum
      join pg_namespace n on n.oid = tbl.relnamespace
     where s.relkind = 'S' and #{USER_NS}
  SQL
end

def amcheck(t)
  psql(t, "create extension if not exists amcheck")
  res = json(t, <<~SQL, helpers: true)
    select c.oid::regclass::text as i, pg_temp.safe_amcheck(c.oid::regclass) as err
      from pg_index x join pg_class c on c.oid = x.indexrelid
      join pg_am am on am.oid = c.relam join pg_namespace n on n.oid = c.relnamespace
     where am.amname = 'btree' and c.relkind = 'i' and x.indisvalid and x.indisready and #{USER_NS}
  SQL
  bad = res.select { _1["err"] }
  corrupt, skipped = bad.partition { _1["err"] =~ /\AXX00[12]|corrupt/i }
  { checked: res.size, corrupt: corrupt.map { "#{_1['i']}: #{_1['err'][0, 140]}" }, skipped: skipped.map { "#{_1['i']}: #{_1['err'][0, 140]}" } }
end

def behind?(s) = s["max_id"].to_f.positive? && (s["last_value"].nil? || s["last_value"].to_f < s["max_id"].to_f)

def baseline ={ schema: fingerprint(PROD), rows: row_counts(PROD), newest: newest(PROD), seqs: sequence_links(PROD) }

def dump(name, *args)
  path = File.join(DUMPS, name)
  _o, err, st = Open3.capture3("pg_dump", "-Fc", "-p", PROD[:port], "-d", PROD[:db], "-f", path, *args)
  raise "pg_dump failed: #{err}" unless st.success?
  path
end

def restore(path, list: nil)
  system("dropdb", "-p", TARGET[:port], "--if-exists", "--force", TARGET[:db], out: File::NULL, err: File::NULL)
  system("createdb", "-p", TARGET[:port], TARGET[:db])
  args = ["pg_restore", *RESTORE_FLAGS, "-p", TARGET[:port], "-d", TARGET[:db]]
  args += ["-L", list] if list
  t0 = Time.now
  _o, err, st = Open3.capture3(*args, path)
  { ok: st.success?, error: err.lines.grep(/error/i).first(2).join(" ").strip, secs: (Time.now - t0).round(1) }
end

def check(base, path, list: nil)
  f = []
  r = restore(path, list: list)
  return [[["CRITICAL", "restore", r[:error]]], r] unless r[:ok]
  psql(TARGET, "analyze")

  missing = base[:schema] - fingerprint(TARGET)
  f << ["CRITICAL", "schema", "#{missing.size} objects missing, e.g. #{missing.first}"] if missing.any?

  rows = row_counts(TARGET)
  base[:rows].each do |tbl, n|
    m = rows[tbl]
    next if n.nil? || m.nil?
    if n.positive? && m.zero? then f << ["CRITICAL", "rows", "#{tbl}: 0 rows restored, production has #{n}"]
    elsif n.positive? && (n - m).abs.to_f / n > ROW_TOLERANCE then f << ["WARNING", "rows", "#{tbl}: #{m} vs #{n}"]
    end
  end

  if base[:newest] && (rn = newest(TARGET)) && (lag = base[:newest] - rn) > MAX_AGE_S
    f << ["CRITICAL", "freshness", "newest restored data is #{lag.round}s behind production (limit #{MAX_AGE_S}s)"]
  end

  prod_seq = base[:seqs].to_h { [[_1["seq"], _1["col"]], _1] }
  sequence_links(TARGET).each do |s|
    next unless behind?(s)
    p = prod_seq[[s["seq"], s["col"]]]
    next if p && behind?(p) && p["last_value"].to_f <= s["last_value"].to_f
    f << ["CRITICAL", "sequences", "#{s['seq']} at #{s['last_value'] || 'unset'} (production: #{p ? p['last_value'] || 'unset' : '?'}) but #{s['col']} max is #{s['max_id']} → next INSERT fails"]
  end

  a = amcheck(TARGET)
  a[:corrupt].each { f << ["CRITICAL", "amcheck", _1] }
  r.merge!(indexes: a[:checked], amcheck_skipped: a[:skipped], size: psql(TARGET, "select pg_size_pretty(pg_database_size(current_database()))"))
  [f, r]
end

$results = []
def report(name, expect, findings, r)
  verdict = findings.any? { _1[0] == "CRITICAL" } ? "FAIL" : (findings.any? ? "WARN" : "PASS")
  ok = (expect == "PASS") == (verdict == "PASS")
  $results << { scenario: name, expected: expect, verdict: verdict, correct: ok }
  puts "\n=== #{name}  →  #{verdict}   (expected #{expect}: #{ok ? 'correct' : 'WRONG'})"
  puts "    restore #{r[:ok] ? 'ok' : 'FAILED'} in #{r[:secs]}s#{r[:size] ? ", #{r[:size]}, #{r[:indexes]} indexes amchecked, #{r[:amcheck_skipped].size} skipped" : ''}"
  (r[:amcheck_skipped] || []).first(2).each { puts "    [info] amcheck skipped #{_1}" }
  findings.first(5).each { |s, c, m| puts "    [#{s}] #{c}: #{m}" }
  puts "    … #{findings.size - 5} more" if findings.size > 5
end
def na(name, why) = (puts "\n=== #{name}  →  N/A (#{why})"; $results << { scenario: name, verdict: "N/A", correct: nil })

def restorable_without?(base_candidates, &mk)
  base_candidates.each do |tbl|
    path = mk.call(tbl)
    return [tbl, path] if restore(path)[:ok]
  end
  nil
end

FileUtils.mkdir_p(DUMPS)
psql(PROD, "create table if not exists public.zz_drill_heartbeat (ts timestamptz not null)")
psql(PROD, "insert into public.zz_drill_heartbeat values (now())")

good = dump("good.dump")
base = baseline
puts "PROD #{PROD[:db]}: #{base[:rows].size} tables, #{base[:rows].values.compact.sum} rows, #{base[:schema].size} schema objects, #{base[:seqs].size} sequence-linked columns"
pre = base[:seqs].select { behind?(_1) }
puts "[production info] #{pre.size} sequences are already behind their column in production (not a backup problem), e.g. #{pre.first(2).map { "#{_1['seq']}=#{_1['last_value'] || 'unset'} < max #{_1['max_id']}" }.join(', ')}" if pre.any?
report("A healthy backup", "PASS", *check(base, good))

File.binwrite(File.join(DUMPS, "truncated.dump"), File.binread(good)[0, (File.size(good) * 0.6).to_i])
report("B truncated backup file", "FAIL", *check(base, File.join(DUMPS, "truncated.dump")))

leaf = json(PROD, <<~SQL).map { _1["t"] }
  select c.oid::regclass::text as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.relkind = 'r' and not c.relispartition and #{USER_NS} and c.relname <> 'zz_drill_heartbeat'
     and not exists (select 1 from pg_constraint k where k.confrelid = c.oid)
     and not exists (select 1 from pg_inherits i where i.inhparent = c.oid)
   order by c.reltuples desc, c.relname limit 8
SQL
if (hit = restorable_without?(leaf.first(4)) { |t| dump("no_table.dump", "-T", t) })
  report("C2 table missing from backup, restore succeeds (#{hit[0]})", "FAIL", *check(base, hit[1]))
else
  na("C2 table missing from backup", "no excludable table restores cleanly")
end

nonempty = leaf.select { base[:rows][_1].to_i.positive? }
if (hit = restorable_without?(nonempty.first(4)) { |t| dump("no_data.dump", "--exclude-table-data=#{t}") })
  report("D table data excluded (#{hit[0]})", "FAIL", *check(base, hit[1]))
else
  na("D table data excluded", "no non-empty leaf tables")
end

if base[:seqs].any? { _1["max_id"].to_f.positive? }
  list = File.join(DUMPS, "no_seq.list")
  toc, = Open3.capture2("pg_restore", "-l", good)
  File.write(list, toc.lines.reject { _1.include?("SEQUENCE SET") }.join)
  report("E sequence values not restored", "FAIL", *check(base, good, list: list))
else
  na("E sequence values not restored", "no sequence-backed column holds data")
end

stale = dump("stale.dump")
sleep STALE_SLEEP_S
psql(PROD, "insert into public.zz_drill_heartbeat values (now())")
report("F stale backup (prod written #{STALE_SLEEP_S}s after backup)", "FAIL", *check(baseline, stale))

scored = $results.reject { _1[:correct].nil? }
puts "\nSUMMARY #{PROD[:db]}: #{scored.count { _1[:correct] }}/#{scored.size} classified correctly, #{$results.count { _1[:correct].nil? }} N/A"
File.write("results-#{PROD[:db]}.json", JSON.pretty_generate($results))
exit(scored.all? { _1[:correct] } ? 0 : 1)
