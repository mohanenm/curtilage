# frozen_string_literal: true

require "json"
require "open3"

# The corrections log (corrections.csv): one row per label change, with why,
# what was checked, whether the review sample was looked at, and whether the
# change raised or lowered the score under the default and core views (as
# scored by the current rules: a wrong point that becomes right or stops
# counting raises it; a right one that becomes wrong or stops counting
# lowers it). Held-out labels never change, so they never appear here.
module CurtilageBenchmark
  CORRECTION_COLUMNS = %w[date commit site role point old_kind new_kind reason checked sample_reviewed
                          default_effect core_effect].freeze

  module_function

  def corrections_file = File.join(DIR, "corrections.csv")

  # [[point, old kind or nil, new kind or nil]] between two label documents,
  # matching points by exact coordinates (nil: added or deleted).
  def label_diffs(old_doc, new_doc)
    before = kinds_by_point(old_doc)
    after = kinds_by_point(new_doc)
    (before.keys | after.keys).filter_map do |point|
      [point, before[point], after[point]] unless before[point] == after[point]
    end
  end

  def kinds_by_point(doc)
    doc.fetch("features", []).to_h { |f| [f.dig("geometry", "coordinates"), f.dig("properties", "kind")] }
  end

  # true when a view counts the kind as in, false as out, nil when ignored.
  def wanted(view, kind)
    return true if view["in"].include?(kind)

    view["out"].include?(kind) ? false : nil
  end

  # :raised, :lowered or :none for one change ([point, old kind, new kind])
  # under a view, given the site's premises in metres (xy, or nil for no
  # premises).
  def correction_effect(view, xy, pin, change)
    point, old_kind, new_kind = change
    inside = !xy.nil? && G.contains?(xy, G.project([point], pin).first)
    right = ->(kind) { (want = kind && wanted(view, kind)).nil? ? nil : want == inside }
    before = right.call(old_kind)
    after = right.call(new_kind)
    return :none if before == after
    return :raised if before == false # a wrong point became right or stopped counting
    return :lowered if before == true

    after ? :raised : :lowered
  end

  # Rows for every change to a tuning or validation site's labels in the
  # commits since `since`, scored with the current rings
  # ({ id => [[lng, lat], ...] }).
  def backfill_corrections(since, rings, sites: self.sites, views: self.views(*paths[:views]))
    by_id = sites.to_h { |s| [s["id"], s] }
    label_commits(since).flat_map do |sha, date, subject|
      modified_labels(sha).flat_map do |path|
        site = by_id[File.basename(path, ".geojson")]
        next [] unless site && role(site) != "holdout"

        commit_rows([sha, date, subject], path, site, rings[site["id"]], views)
      end
    end
  end

  # [[sha, date, subject], ...] oldest first.
  def label_commits(since)
    log = git("log", "--reverse", "--format=%H %as %s", "#{since}..HEAD", "--", "benchmark/labels")
    log.lines(chomp: true).map { |line| line.split(" ", 3) }
  end

  # Label files the commit changed (not added).
  def modified_labels(sha)
    changes = git("diff-tree", "--no-commit-id", "--name-status", "-r", sha, "--", "benchmark/labels")
    changes.lines(chomp: true).filter_map do |line|
      status, path = line.split("\t")
      path if status == "M"
    end
  end

  def commit_rows((sha, date, subject), path, site, ring, views)
    xy = ring && G.counter_clockwise(G.open_ring(G.project(ring, site["pin"])))
    diffs = label_diffs(JSON.parse(git("show", "#{sha}^:#{path}")), JSON.parse(git("show", "#{sha}:#{path}")))
    diffs.map do |change|
      point, old_kind, new_kind = change
      effects = %w[default core].map { |v| correction_effect(views.fetch(v), xy, site["pin"], change).to_s }
      [date, sha[0, 7], site["id"], role(site), point.join(" "), old_kind || "(none)", new_kind || "(deleted)", subject,
       "backfilled from git: the commit message gives the reason", "n/a (before the review rule)", *effects]
    end
  end

  def git(*args)
    out, status = Open3.capture2("git", "-C", ROOT, *args)
    raise "git #{args.first} failed" unless status.success?

    out
  end

  # Helped against hurt: { view => { "raised" => n, "lowered" => n, "none" => n } }.
  def corrections_balance(rows)
    %w[default_effect core_effect].to_h do |column|
      [column.sub("_effect", ""), rows.map { |r| r[column] }.tally]
    end
  end

  # Every field quoted (points start with "-"), read back with the gem's
  # strict RFC 4180 reader: no csv gem needed.
  def write_corrections(rows, file = corrections_file)
    line = ->(fields) { fields.map { |v| "\"#{v.to_s.gsub('"', '""')}\"" }.join(",") }
    File.write(file, "#{([line.call(CORRECTION_COLUMNS)] + rows.map { |r| line.call(r) }).join("\n")}\n")
  end

  def append_corrections(rows, file = corrections_file)
    write_corrections(read_corrections(file).map { |r| r.values_at(*CORRECTION_COLUMNS) } + rows, file)
  end

  def read_corrections(file = corrections_file)
    return [] unless File.file?(file)

    head, *rows = Curtilage::Formats.parse_csv(File.read(file, encoding: "utf-8"))
    rows.map { |r| head.zip(r).to_h }
  end
end
