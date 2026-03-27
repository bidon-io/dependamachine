#!/usr/bin/env ruby
# frozen_string_literal: true

# Shared CocoaPods dependency updater.
# Reads project-specific configuration from a JSON config file.
#
# Usage:
#   ruby pods_updater.rb [--config path/to/config.json]
#
# Environment variables:
#   GITHUB_TOKEN          - GitHub token for API calls
#   PODS_UPDATER_TOKEN    - Optional PAT for git push (generates events)
#   PODS_BASE_BRANCH      - Override base branch (default from config)
#   PODS_REVIEWERS        - Comma-separated reviewers (users or org/team)
#   POD_BIN               - Path to `pod` binary
#   CONFIG_PATH           - Alternative to --config flag

require 'json'
require 'net/http'
require 'uri'
require 'rubygems/version'
require 'optparse'

TRUNK_BASE = 'https://trunk.cocoapods.org/api/v1/pods'

# --- Config loading ---

def load_config(path)
  unless File.exist?(path)
    raise "Config file not found: #{path}"
  end
  JSON.parse(File.read(path))
end

def parse_options
  options = { config: ENV['CONFIG_PATH'] || '.github/pods-updater-config.json' }
  OptionParser.new do |opts|
    opts.banner = "Usage: pods_updater.rb [--config path]"
    opts.on('--config PATH', 'Path to project config JSON') { |v| options[:config] = v }
  end.parse!
  options
end

OPTIONS = parse_options
CONFIG = load_config(OPTIONS[:config])

# Project-specific settings from config
POD_TO_ADAPTER    = (CONFIG['pod_to_adapter'] || {}).freeze
ADAPTER_PREFIX    = CONFIG['adapter_prefix'] || 'BidonAdapter'
ADAPTERS_DIR      = CONFIG['adapters_dir'] || 'Adapters'
WORKSPACE         = CONFIG['workspace'] || 'BidOn.xcworkspace'
BRANCH_PREFIX     = CONFIG['branch_prefix'] || 'chore/pod-'
COMMIT_PREFIX     = CONFIG['commit_prefix'] || 'chore(pods):'
ADAPTER_VERSION_REGEX = CONFIG['adapter_version_regex'] || 'adapterVersion\s*:\s*String\s*=\s*"(\d+)"'
ADAPTER_CHANGELOG = CONFIG.fetch('adapter_changelog', true)
PR_LABELS         = CONFIG['pr_labels'] || %w[dependencies cocoapods]

# --- Environment ---

def repo_slug
  ENV.fetch('GITHUB_REPOSITORY')
end

def github_token
  ENV.fetch('GITHUB_TOKEN')
end

def api_token
  ENV['PODS_UPDATER_TOKEN'].to_s.empty? ? github_token : ENV['PODS_UPDATER_TOKEN']
end

def git_push_token
  ENV['PODS_UPDATER_TOKEN'].to_s.empty? ? github_token : ENV['PODS_UPDATER_TOKEN']
end

def default_branch
  ENV['PODS_BASE_BRANCH'] || CONFIG['base_branch'] || 'dev'
end

# --- HTTP helpers ---

def http_get_json(url)
  cmd = ["curl", "-fsSL", "--retry", "3", "--retry-delay", "1", url]
  body = IO.popen(cmd, &:read)
  raise "curl failed for #{url}" unless $?.success?
  JSON.parse(body)
end

# --- Version helpers ---

def semver_key(v)
  v.to_s.split(/[\.\-]/).map { |p| p =~ /^\d+$/ ? p.to_i : p }
end

def read_lock_versions(lock_path)
  versions = {}
  return versions unless File.exist?(lock_path)
  in_pods = false
  sanitize = proc do |raw|
    v = raw.to_s.strip
    v = v.sub(/^~>\s*/, "").sub(/^>=\s*/, "").sub(/^<=\s*/, "").sub(/^==\s*/, "").sub(/^=\s*/, "")
    v.gsub(/[^0-9A-Za-z\.\-]/, "")
  end
  File.foreach(lock_path) do |line|
    if line.start_with?("PODS:")
      in_pods = true
      next
    end
    if in_pods && line.match?(/^[A-Z][A-Z ]+:/)
      in_pods = false
    end
    next unless in_pods
    next unless line.start_with?("  - ")
    entry = line.sub(/^  - /, "").strip
    name, ver = entry.split(" (", 2)
    next unless name && ver
    v = ver.to_s.delete(")").strip
    v = sanitize.call(v)
    versions[name] = v if v.match(/^\d/)
  end
  versions
end

def adapter_revision(adapter_name)
  dir = File.join(ADAPTERS_DIR, adapter_name)
  # Try project-specific pattern first, then common patterns
  patterns = [
    File.join(dir, "**", "*DemandSourceAdapter.swift"),
    File.join(dir, "**", "*Adapter.swift")
  ]
  candidates = patterns.flat_map { |p| Dir.glob(p) }.uniq
  return "0" if candidates.empty?
  begin
    content = File.read(candidates.first)
    re = Regexp.new(ADAPTER_VERSION_REGEX)
    m = content.match(re)
    return m[1] if m
  rescue => e
    warn "Could not read adapterVersion from #{candidates.first}: #{e}"
  end
  "0"
end

def compute_adapter_version(adapter_name, pod_name, sdk_version_hint)
  lock_versions = read_lock_versions("Podfile.lock")
  root = pod_name.to_s.split('/').first
  base = lock_versions[pod_name] || lock_versions[root] || sdk_version_hint
  rev  = adapter_revision(adapter_name)
  "#{base}.#{rev}"
end

# --- Podfile parsing ---

def parse_podfile_entries
  src = File.read('Podfile')
  entries = []
  src.each_line.with_index(1) do |line, ln|
    if line =~ /^\s*pod\s+["']([^"']+)["']\s*(?:,\s*["']([^"']+)["'])?/
      name = Regexp.last_match(1)
      ver  = Regexp.last_match(2)
      entries << { line_no: ln, name: name, version: ver }
    end
  end
  entries
end

def exact_version?(s)
  return false if s.nil? || s.empty?
  !!(s =~ /^\d+(\.\d+)*$/)
end

# --- Trunk API ---

def trunk_versions_for(pod)
  root = pod.to_s.split('/').first
  begin
    data = http_get_json("#{TRUNK_BASE}/#{URI.encode_www_form_component(root)}")
  rescue => e
    if e.message.include?('HTTP 404')
      warn "Skip #{pod}: not found in Trunk"
      return []
    end
    raise
  end
  versions = (data['versions'] || []).map { |x| x['name'] }.compact.uniq
  versions.sort_by { |v| Gem::Version.new(v) }
end

# --- Podfile modification ---

def replace_pod_version_in_podfile(pod, to_version)
  src = File.read('Podfile')
  changed = false
  new_src = src.gsub(/^(\s*pod\s+["']#{Regexp.escape(pod)}["'])\s*(?:,\s*["']([^"']+)["'])?/) do
    prefix = Regexp.last_match(1)
    changed = true
    %(#{prefix}, '#{to_version}')
  end
  raise "Pod '#{pod}' not found in Podfile" unless changed
  File.write('Podfile', new_src)
end

# --- Adapter changelog ---

def update_adapter_changelog(adapter_name, pod_name, sdk_version_hint)
  return unless ADAPTER_CHANGELOG

  path = File.join(ADAPTERS_DIR, adapter_name, "CHANGELOG.md")
  unless File.exist?(path)
    warn "CHANGELOG not found for #{adapter_name} (#{path})"
    return
  end

  adapter_ver = compute_adapter_version(adapter_name, pod_name, sdk_version_hint)
  content = File.read(path)
  return if content.include?("## #{adapter_ver}")

  lines = content.lines
  idx = lines.index { |l| l.start_with?("# Changelog") } || 0
  insert_at = idx + 1

  while lines[insert_at]&.strip&.empty?
    lines.delete_at(insert_at)
  end

  block = []
  block << "\n"
  block << "## #{adapter_ver}\n"
  root = pod_name.to_s.split('/').first
  lock_versions = read_lock_versions("Podfile.lock")
  sdk_ver = lock_versions[pod_name] || lock_versions[root] || sdk_version_hint
  block << "* Updated to #{pod_name} #{sdk_ver}\n"
  block << "\n"

  lines.insert(insert_at, *block)
  File.write(path, lines.join)
rescue => e
  warn "Failed to update CHANGELOG for #{adapter_name}: #{e}"
end

# --- Shell / Git helpers ---

def sh!(cmd)
  puts ">> #{cmd}"
  ok = system(cmd)
  raise "Command failed: #{cmd}" unless ok
end

def git_reset_to_default
  sh!("git fetch origin #{default_branch}")
  sh!("git checkout -B #{default_branch} origin/#{default_branch}")
  sh!("git reset --hard origin/#{default_branch}")
  sh!("git clean -fd")
end

def git_push_branch(branch)
  owner, repo = repo_slug.split('/', 2)
  if ENV['PODS_UPDATER_TOKEN'].to_s.empty?
    puts '>> git_push: using GITHUB_TOKEN'
  else
    puts '>> git_push: using PODS_UPDATER_TOKEN'
  end
  remote = "https://x-access-token:#{git_push_token}@github.com/#{owner}/#{repo}.git"
  ok = system("git push -u #{remote} HEAD:#{branch} --force-with-lease")
  unless ok
    system("git fetch origin #{branch}")
    sh!("git push -u #{remote} HEAD:#{branch} --force")
  end
end

# --- PR creation ---

def create_pr(branch, title, body, labels: PR_LABELS)
  owner, repo = repo_slug.split('/', 2)
  uri = URI("https://api.github.com/repos/#{owner}/#{repo}/pulls")
  payloads = [
    { title: title, head: branch, base: default_branch, body: body, maintainer_can_modify: true },
    { title: title, head: "#{owner}:#{branch}", base: default_branch, body: body, maintainer_can_modify: true }
  ]
  pr = nil
  last_resp = nil
  created = false
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    payloads.each do |pl|
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{api_token}"
      req['Accept'] = 'application/vnd.github+json'
      req.body = pl.to_json
      resp = http.request(req)
      last_resp = resp
      if resp.is_a?(Net::HTTPSuccess)
        pr = JSON.parse(resp.body)
        created = (resp.code.to_s == '201')
        break
      end
    end
  end
  if pr.nil? && last_resp && last_resp.code.to_s == '422'
    list_uri = URI("https://api.github.com/repos/#{owner}/#{repo}/pulls?head=#{owner}%3A#{branch}&base=#{default_branch}&state=open")
    list_req = Net::HTTP::Get.new(list_uri)
    list_req['Authorization'] = "Bearer #{api_token}"
    list_req['Accept'] = 'application/vnd.github+json'
    Net::HTTP.start(list_uri.host, list_uri.port, use_ssl: true) do |http|
      list_resp = http.request(list_req)
      if list_resp.is_a?(Net::HTTPSuccess)
        arr = JSON.parse(list_resp.body)
        pr = arr.first if arr.is_a?(Array) && !arr.empty?
      end
    end
    puts ">> Found existing PR for #{branch}: ##{pr['number']}" if pr
  end
  raise "PR create failed: #{last_resp&.code} #{last_resp&.body}" unless pr

  # Add labels
  issues_uri = URI("https://api.github.com/repos/#{owner}/#{repo}/issues/#{pr['number']}/labels")
  lab_req = Net::HTTP::Post.new(issues_uri)
  lab_req['Authorization'] = "Bearer #{api_token}"
  lab_req['Accept'] = 'application/vnd.github+json'
  lab_req.body = { labels: labels }.to_json
  Net::HTTP.start(issues_uri.host, issues_uri.port, use_ssl: true) { |http| http.request(lab_req) }

  # Request reviewers
  reviewers_csv = ENV['PODS_REVIEWERS'].to_s.strip
  unless reviewers_csv.empty?
    users = []
    teams = []
    reviewers_csv.split(',').map(&:strip).each do |entry|
      if entry.include?('/')
        teams << entry.split('/', 2).last
      elsif !entry.empty?
        users << entry
      end
    end
    if users.any? || teams.any?
      rr_uri = URI("https://api.github.com/repos/#{owner}/#{repo}/pulls/#{pr['number']}/requested_reviewers")
      rr_req = Net::HTTP::Post.new(rr_uri)
      rr_req['Authorization'] = "Bearer #{api_token}"
      rr_req['Accept'] = 'application/vnd.github+json'
      rr_req.body = { reviewers: users, team_reviewers: teams }.to_json
      rr_resp = nil
      Net::HTTP.start(rr_uri.host, rr_uri.port, use_ssl: true) { |http| rr_resp = http.request(rr_req) }
      if rr_resp.is_a?(Net::HTTPSuccess)
        puts ">> Requested reviewers: users=#{users.join(',')} teams=#{teams.join(',')}"
      else
        warn "Request reviewers failed: #{rr_resp.code} #{rr_resp.body}"
        unless users.empty?
          assign_uri = URI("https://api.github.com/repos/#{owner}/#{repo}/issues/#{pr['number']}/assignees")
          assign_req = Net::HTTP::Post.new(assign_uri)
          assign_req['Authorization'] = "Bearer #{api_token}"
          assign_req['Accept'] = 'application/vnd.github+json'
          assign_req.body = { assignees: users }.to_json
          Net::HTTP.start(assign_uri.host, assign_uri.port, use_ssl: true) do |http|
            assign_resp = http.request(assign_req)
            if assign_resp.is_a?(Net::HTTPSuccess)
              puts ">> Assigned as fallback: users=#{users.join(',')}"
            else
              warn "Assign fallback result: #{assign_resp.code} #{assign_resp.body}"
            end
          end
        end
      end
    end
  end
  [pr, created]
end

def pr_body(pod, from_v, to_v, adapters: [])
  meta = { pod: pod, from: from_v, to: to_v, adapters: adapters }
  <<~MD
  Update CocoaPods dependency

  - #{pod}: #{from_v || 'unset'} → #{to_v}

  <!-- build-metadata
  #{JSON.pretty_generate(meta)}
  -->
  MD
end

# --- Main ---

def main
  git_reset_to_default
  entries = parse_podfile_entries
  exact = entries.select { |e| exact_version?(e[:version]) }

  # Filter: only process pods that are in our mapping
  monitored_pods = POD_TO_ADAPTER.keys.map { |k| k.split('/').first }.uniq
  exact = exact.select { |e| monitored_pods.include?(e[:name].split('/').first) } if monitored_pods.any?

  return if exact.empty?

  exact.each do |e|
    pod = e[:name]
    cur = e[:version]
    all = trunk_versions_for(pod)
    cur_v = Gem::Version.new(cur)
    newer = all.select { |v| Gem::Version.new(v) > cur_v }
    next if newer.empty?

    newer.each do |to_v|
      puts "\n=============================="
      puts "Processing SDK #{pod} #{cur} -> #{to_v}"
      puts "=============================="
      branch = "#{BRANCH_PREFIX}#{pod}-#{to_v}"
      sh!("git fetch origin #{default_branch}")
      sh!("git checkout -B #{branch} origin/#{default_branch}")
      replace_pod_version_in_podfile(pod, to_v)
      pod_bin = ENV['POD_BIN'] || 'pod'
      sh!("#{pod_bin} update #{pod} --no-repo-update")
      # Update adapter changelogs
      adapter_key = pod.split('/').first
      (POD_TO_ADAPTER[adapter_key] || POD_TO_ADAPTER[pod] || []).each do |adapter_name|
        update_adapter_changelog(adapter_name, pod, to_v)
      end
      sh!("git add Podfile Podfile.lock #{ADAPTERS_DIR}/*/CHANGELOG.md")
      msg = "#{COMMIT_PREFIX} #{pod} #{cur} -> #{to_v}"
      sh!(%{git commit -m "#{msg}"})
      git_push_branch(branch)
      begin
        create_pr(branch, msg, pr_body(pod, cur, to_v, adapters: POD_TO_ADAPTER[adapter_key] || POD_TO_ADAPTER[pod] || []))
      rescue => e
        if e.message.include?('422') && e.message.include?('already exists')
          # no-op
        else
          raise
        end
      end
      git_reset_to_default
    end
  end
end

main
