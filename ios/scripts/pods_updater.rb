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
require 'digest'
require 'rubygems/version'
require 'optparse'

TRUNK_BASE = 'https://trunk.cocoapods.org/api/v1/pods'

# --- HTTP helpers ---

def http_get_json(url)
  cmd = ["curl", "-fsSL", "--retry", "3", "--retry-delay", "1", url]
  body = IO.popen(cmd, &:read)
  raise "curl failed for #{url}" unless $?.success?
  JSON.parse(body)
end

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

# --- Pod-to-adapter mapping ---

# Fetch pod-to-adapter mapping from a remote API.
# The API must return a JSON array where each object has:
#   'own_dependency_ios'  - CocoaPods pod name
#   <field>               - adapter pod name (empty if not supported on iOS)
# +field+ is configurable via 'dependency_field_ios' in config
#   (defaults to 'appodeal_dependency_ios').
# Multiple entries with the same pod name are merged into an array.
def fetch_pod_to_adapter_map_from_api(url, field)
  puts ">> Fetching pod-to-adapter mapping from #{url} (field: #{field})"
  data = http_get_json(url)
  map = {}
  data.each do |entry|
    pod     = entry['own_dependency_ios'].to_s.strip
    adapter = entry[field].to_s.strip
    next if pod.empty? || adapter.empty?
    map[pod] ||= []
    map[pod] << adapter unless map[pod].include?(adapter)
  end
  puts ">> Loaded mapping for #{map.size} pods: #{map.keys.join(', ')}"
  map
end

def load_pod_to_adapter_map(config)
  api_url = config['mapping_api_url'].to_s.strip
  static  = config['pod_to_adapter'] || {}

  return static.freeze if api_url.empty?

  field = config['dependency_field_ios'] || 'appodeal_dependency_ios'
  map   = fetch_pod_to_adapter_map_from_api(api_url, field)

  # Merge: static entries add or extend API results (additive, not replacing).
  # Use this for adapters not yet covered by the API (e.g. third-party adapters
  # for the same SDK: AppLovinMediationBidonAdapter alongside BidonAdapterAppLovin).
  static.each do |pod, adapters|
    map[pod] ||= []
    Array(adapters).each { |a| map[pod] << a unless map[pod].include?(a) }
  end

  map.freeze
rescue => e
  raise "Failed to load pod-to-adapter mapping from API (#{api_url}): #{e}"
end

# Project-specific settings from config
POD_TO_ADAPTER    = load_pod_to_adapter_map(CONFIG)
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

# --- Reverse dependency lookup ---

# Parse Podfile.lock PODS section and find all root pods that have
# an exact (= X.Y.Z) dependency on +target_pod+ at version +version+.
# Returns an array of root pod names (without subspecs).
def find_dependent_pods(lock_path, target_pod, version)
  return [] unless File.exist?(lock_path)
  dependents = []
  in_pods = false
  current_root = nil
  root_pod = target_pod.split('/').first

  File.foreach(lock_path) do |line|
    if line.start_with?("PODS:")
      in_pods = true
      next
    end
    break if in_pods && line.match?(/^[A-Z][A-Z ]+:/) && !line.start_with?("PODS:")

    next unless in_pods

    # Root-level pod entry: "  - PodName (version):"
    if line =~ /^  - ([^\s(]+)\s*\(/
      current_root = Regexp.last_match(1).split('/').first
    # Dependency line: "    - OtherPod (= 1.2.3)"
    elsif line =~ /^    - ([^\s(]+)\s*\(=\s*#{Regexp.escape(version)}\)/
      dep_name = Regexp.last_match(1).split('/').first
      if dep_name == root_pod && current_root && current_root != root_pod
        dependents << current_root unless dependents.include?(current_root)
      end
    end
  end
  dependents
end

# Parse the Podfile.lock PODS section into a dependency graph.
# Returns { "PodName" => ["DepName", ...], "PodName/Subspec" => [...] }
# preserving subspec names exactly as they appear in the lockfile.
def parse_lock_dependency_graph(lock_path)
  graph = {}
  return graph unless File.exist?(lock_path)
  in_pods = false
  current = nil
  File.foreach(lock_path) do |line|
    if line.start_with?("PODS:")
      in_pods = true
      next
    end
    break if in_pods && line.match?(/^[A-Z][A-Z ]+:/) && !line.start_with?("PODS:")
    next unless in_pods

    if line =~ /^  - "?([^\s"(]+)"?\s*\(/
      current = Regexp.last_match(1)
      graph[current] ||= []
    elsif current && line =~ /^    - "?([^\s"(]+)"?/
      dep = Regexp.last_match(1)
      graph[current] << dep unless graph[current].include?(dep)
    end
  end
  graph
end

# Collect root pod names reachable from +seed_pods+ through the Podfile.lock
# dependency graph (excluding the seeds themselves). Used to expand the
# `pod update` argument list so transitive dependencies (e.g. GoogleAppMeasurement
# for Firebase/Analytics) aren't held back at their old locked versions while
# their parents try to move forward.
def transitive_root_dependencies(lock_path, seed_pods)
  graph = parse_lock_dependency_graph(lock_path)
  seed_roots = seed_pods.map { |p| p.split('/').first }.uniq
  # visited tracks exact graph nodes (which may include subspec names) so we
  # don't stop at the first subspec of a multi-subspec pod — different subspecs
  # of the same root can pull in different downstream dependencies.
  visited = seed_pods.dup
  queue   = seed_pods.dup
  result  = []
  until queue.empty?
    node = queue.shift
    (graph[node] || []).each do |dep|
      unless visited.include?(dep)
        visited << dep
        queue   << dep
      end
      dep_root = dep.split('/').first
      # Also walk the root entry so deps declared only at the root level
      # are discovered when we entered through a subspec.
      if dep != dep_root && graph.key?(dep_root) && !visited.include?(dep_root)
        visited << dep_root
        queue   << dep_root
      end
      next if seed_roots.include?(dep_root)
      result << dep_root unless result.include?(dep_root)
    end
  end
  result
end

# --- Compatibility check via CocoaPods CDN ---

# Fetch podspec JSON from the public CocoaPods CDN.
def fetch_podspec_from_cdn(name, version)
  hash = Digest::MD5.hexdigest(name)
  url = "https://cdn.cocoapods.org/Specs/#{hash[0]}/#{hash[1]}/#{hash[2]}/#{name}/#{version}/#{name}.podspec.json"
  http_get_json(url)
rescue => e
  nil
end

# Extract the exact-pinned version of +target_pod+ from a podspec's dependencies.
# Looks at both top-level "dependencies" and platform-specific blocks
# (e.g. "ios.dependencies"). CocoaPods treats a constraint with no operator
# as an exact match, so both "= 6.18.0" and bare "6.18.0" are recognized.
def pinned_dependency_version(spec, target_pod)
  root = target_pod.split('/').first
  dep_blocks = [spec['dependencies']]
  %w[ios osx tvos watchos visionos macos].each do |platform|
    pblock = spec[platform]
    dep_blocks << pblock['dependencies'] if pblock.is_a?(Hash)
  end
  dep_blocks.compact.each do |deps|
    deps.each do |dep_name, constraints|
      # Match the root pod or any of its subspecs (e.g. AppsFlyerFramework/Strict
      # → same root version as AppsFlyerFramework).
      next unless dep_name == root || dep_name.to_s.start_with?("#{root}/")
      next unless constraints.is_a?(Array)
      constraints.each do |constraint|
        if constraint.to_s.strip =~ /\A=?\s*(\d[\w.\-]*)\z/
          return Regexp.last_match(1)
        end
      end
    end
  end
  (spec['subspecs'] || []).each do |sub|
    v = pinned_dependency_version(sub, target_pod)
    return v if v
  end
  nil
end

# For each dependent pod available on public Trunk/CDN, build a map of
# supported target_pod versions to the latest adapter version that supports them.
# Returns { dep_name => { sdk_version => adapter_version } }. Private pods are skipped.
def build_supported_versions_map(target_pod, dependent_pods, current_version)
  map = {}
  cur_v = Gem::Version.new(current_version)

  dependent_pods.each do |dep|
    versions = trunk_versions_for(dep)
    if versions.empty?
      puts ">> #{dep}: not on public Trunk, skipping compatibility check"
      next
    end

    sdk_to_adapter = {}
    checked = 0
    versions.reverse_each do |ver|
      spec = fetch_podspec_from_cdn(dep, ver)
      next unless spec
      checked += 1
      sdk_ver = pinned_dependency_version(spec, target_pod)
      next unless sdk_ver
      begin
        if Gem::Version.new(sdk_ver) >= cur_v
          # Keep the latest (first seen) adapter version for each SDK version
          sdk_to_adapter[sdk_ver] ||= ver
        else
          break # older adapter versions only pin older SDK versions
        end
      rescue ArgumentError
        next
      end
      # Stop after finding a version matching current — we have the full range
      break if sdk_ver == current_version && checked > 1
    end

    map[dep] = sdk_to_adapter
    supported = sdk_to_adapter.keys.sort_by { |v| Gem::Version.new(v) rescue v }
    puts ">> #{dep} supports #{target_pod}: #{supported.join(', ')}"
  end

  map
end

# Find the highest candidate version of target_pod that ALL public dependent
# adapters support. Private pods (not on Trunk) are excluded from constraints.
# Dependents whose podspecs never pin target_pod with an exact (= X.Y.Z)
# constraint are also excluded: their compatibility cannot be inferred from
# podspec metadata and treating them as "supports nothing" would block all
# upgrades (e.g. FBSDKLoginKit declares FBSDKCoreKit with ~> instead of =).
# Returns [version, compat_map] or [nil, compat_map].
def find_best_compatible_version(target_pod, current_version, candidates, dependent_pods)
  if dependent_pods.empty?
    return [candidates.last, {}]
  end

  map = build_supported_versions_map(target_pod, dependent_pods, current_version)
  constraining = map.reject { |_dep, sdk_to_adapter| sdk_to_adapter.empty? }
  if constraining.empty?
    return [candidates.last, map] # no public deps with exact pins to constrain
  end

  candidates.sort_by { |v| Gem::Version.new(v) }.reverse_each do |v|
    if constraining.all? { |_dep, sdk_to_adapter| sdk_to_adapter.key?(v) }
      return [v, map]
    end
  end

  [nil, map]
end

# Update version pins in Podfile for dependent pods that already have exact pins.
# Uses compat_map from build_supported_versions_map to find the right adapter version.
def update_dependent_versions_in_podfile(compat_map, target_version)
  entries = parse_podfile_entries
  pinned_names = entries.select { |e| exact_version?(e[:version]) }.map { |e| e[:name] }

  compat_map.each do |dep, sdk_to_adapter|
    next unless pinned_names.include?(dep)
    adapter_ver = sdk_to_adapter[target_version]
    next unless adapter_ver
    replace_pod_version_in_podfile(dep, adapter_ver)
    puts ">> Updated #{dep} to #{adapter_ver} in Podfile"
  end
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

# Find sibling subspecs of +pod+ pinned to an exact version in the Podfile.
# For "Firebase/Core" returns the other "Firebase/*" entries (e.g. "Firebase/Analytics",
# "Firebase/RemoteConfig"). All Firebase subspecs must share the same version, so when
# bumping Firebase/Core we must bump the siblings too — otherwise `pod update` cannot
# resolve a single Firebase version that satisfies all pins.
def find_sibling_subspecs(pod, podfile_entries)
  return [] unless pod.include?('/')
  root = pod.split('/').first
  podfile_entries
    .select { |e| e[:name] != pod }
    .select { |e| e[:name].start_with?("#{root}/") }
    .select { |e| exact_version?(e[:version]) }
    .map    { |e| e[:name] }
    .uniq
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

  processed_pods = []

  exact.each do |e|
    pod = e[:name]
    cur = e[:version]
    next if processed_pods.include?(pod)
    all = trunk_versions_for(pod)
    cur_v = Gem::Version.new(cur)
    newer = all.select { |v| Gem::Version.new(v) > cur_v }
    next if newer.empty?

    # Sibling subspecs of the same root (e.g. Firebase/Analytics for Firebase/Core)
    # must move in lockstep — we'll bump them in Podfile and pass them to pod update.
    siblings = find_sibling_subspecs(pod, entries)
    if siblings.any?
      puts "\n>> Sibling subspecs for #{pod}: #{siblings.join(', ')} (will be bumped together)"
    end

    # Find dependent pods and the best version compatible with all adapters
    dependent = find_dependent_pods('Podfile.lock', pod, cur)
    compat_map = {}
    if dependent.any?
      puts "\n>> Dependent adapters for #{pod}: #{dependent.join(', ')}"
      best, compat_map = find_best_compatible_version(pod, cur, newer, dependent)
      if best.nil?
        puts ">> Skipping #{pod}: no version compatible with all dependent adapters"
        next
      end
      if best != newer.last
        puts ">> Constraining #{pod} to #{best} (latest available: #{newer.last}) for adapter compatibility"
      end
      newer = [best]
    else
      newer = [newer.last]
    end

    newer.each do |to_v|
      puts "\n=============================="
      puts "Processing SDK #{pod} #{cur} -> #{to_v}"
      puts "=============================="
      # When siblings travel together, name the branch after the root pod
      # so we don't create N branches for the same effective change.
      branch_pod = siblings.any? ? pod.split('/').first : pod
      branch = "#{BRANCH_PREFIX}#{branch_pod}-#{to_v}"
      sh!("git fetch origin #{default_branch}")
      sh!("git checkout -B #{branch} origin/#{default_branch}")
      replace_pod_version_in_podfile(pod, to_v)
      siblings.each { |sib| replace_pod_version_in_podfile(sib, to_v) }
      # Update version pins for dependent pods that have exact pins in Podfile
      update_dependent_versions_in_podfile(compat_map, to_v) if compat_map.any?
      pod_bin = ENV['POD_BIN'] || 'pod'
      # Include sibling subspecs and dependent pods in update so they resolve together
      seeds = ([pod] + siblings + dependent).uniq
      # Also unlock transitive deps from Podfile.lock — otherwise pods like
      # GoogleAppMeasurement (a transitive dep of Firebase/Analytics that is
      # itself a root pod in the lockfile) stay pinned to their old version
      # and block resolution of the new parent.
      transitive = transitive_root_dependencies('Podfile.lock', seeds) - seeds
      update_pods = (seeds + transitive).uniq
      if dependent.any?
        puts ">> Also updating dependent pods: #{dependent.join(', ')}"
      end
      if transitive.any?
        puts ">> Also unlocking transitive deps: #{transitive.join(', ')}"
      end
      sh!("#{pod_bin} update #{update_pods.join(' ')} --no-repo-update")
      # Update adapter changelogs
      adapter_key = pod.split('/').first
      (POD_TO_ADAPTER[adapter_key] || POD_TO_ADAPTER[pod] || []).each do |adapter_name|
        update_adapter_changelog(adapter_name, pod, to_v)
      end
      sh!("git add Podfile Podfile.lock")
      system("git add #{ADAPTERS_DIR}/*/CHANGELOG.md 2>/dev/null")
      msg_pod = siblings.any? ? pod.split('/').first : pod
      msg = "#{COMMIT_PREFIX} #{msg_pod} #{cur} -> #{to_v}"
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

    processed_pods << pod
    siblings.each { |sib| processed_pods << sib }
  end
end

main
