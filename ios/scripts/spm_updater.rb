#!/usr/bin/env ruby
# frozen_string_literal: true

# Shared SPM dependency updater with a version-coherence gatekeeper.
#
# SwiftPM resolves ONE graph per workspace and the project pins network SDKs
# with exact versions, so a network SDK version must be identical for every
# consumer: the project's own adapter, MAX mediation, LevelPlay mediation and
# the Bidon adapter pods. The update cascade therefore is:
#
#   1. MAX gate (primary): a new SDK version is only taken when AppLovin has
#      published a mediation adapter for it. No MAX adapter — no bump at all.
#   2. Own pin bump: the exactVersion in the Xcode project (or the binaryTarget
#      url/checksum in a local override package manifest).
#   3. LevelPlay gate (secondary): if IronSource published an adapter pinning
#      the new SDK version, its pin is bumped; otherwise the LevelPlay adapter
#      package is REMOVED from the build and recorded in the deferred store.
#   4. Bidon gate (secondary): same for BidonAdapter* pods — bump the pod pin
#      or comment the pod out and defer.
#   5. Restore pass: every run re-checks the deferred store and restores
#      entries whose stack caught up with the current SDK version.
#
# Usage:
#   ruby spm_updater.rb [--config path/to/config.json] [--dry-run]
#
# Environment variables (same conventions as pods_updater.rb):
#   GITHUB_TOKEN          - GitHub token for API calls
#   PODS_UPDATER_TOKEN    - Optional PAT for git push (generates events)
#   PODS_BASE_BRANCH      - Override base branch (default from config)
#   PODS_REVIEWERS        - Comma-separated reviewers (users or org/team)
#   POD_BIN               - Path to `pod` binary
#   CONFIG_PATH           - Alternative to --config flag
#
# Config schema (JSON, lives in the consuming repo):
# {
#   "workspace": "Appodeal.xcworkspace",
#   "base_branch": "develop",
#   "branch_prefix": "chore/spm-",
#   "commit_prefix": "chore(spm):",
#   "pr_labels": ["dependencies", "spm"],
#   "adapters_yml": "fastlane/adapters.yml",
#   "deferred_path": ".github/spm-deferred.json",
#   "resolve_schemes": ["Sandbox"],
#   "adapters_dir": "Adapters",
#   "networks": {
#     "<Name>": {
#       "adapter": "Appodeal<Name>Adapter",          // for changelog + PR meta
#       "sdk_repo": "https://github.com/...",         // upstream SPM repo
#       "tag_style": "plain",                         // or "v-prefixed"
#       "pin": {                                      // where the workspace pin lives
#         "type": "pbxproj",                          // or "local_manifest"
#         "file": "Adapters/AppodealAdapters.xcodeproj/project.pbxproj",
#         "reference": "BidMachine-SPM"               // XCRemoteSwiftPackageReference comment name
#         // local_manifest: { "type": "local_manifest", "file": "LocalPackages/X/Package.swift" }
#       },
#       "adapters_yml_pin_override": "MintegralAdSDK",// optional pin_overrides key to sync
#       "max_adapter": {                              // primary gate; omit to skip the gate
#         "repo": "https://github.com/AppLovin/AppLovin-MAX-Swift-Package-<X>",
#         "tag_style": "applovin_encoded"
#       },
#       "levelplay_adapter": {                        // secondary gate; omit if none
#         "repo": "https://github.com/ironsource-mobile/LevelPlay-<X>-Adapter-Swift-Package",
#         "pin": { "type": "pbxproj", "file": "Sandbox/Sandbox.xcodeproj/project.pbxproj",
#                  "reference": "LevelPlay-<X>-Adapter-Swift-Package" },
#         "sdk_dep_url_substring": "VungleAdsSDK-SwiftPackageManager",
#         "target_name": "Sandbox",                   // where to re-add on restore
#         "product": "VungleAdapter"
#       },
#       "bidon_adapter": { "pod": "BidonAdapter<X>" } // secondary gate; omit if none
#     }
#   }
# }

require 'json'
require 'net/http'
require 'uri'
require 'digest'
require 'rubygems/version'
require 'optparse'

TRUNK_BASE = 'https://trunk.cocoapods.org/api/v1/pods'

# --- Options / config ---

def parse_options
  options = { config: ENV['CONFIG_PATH'] || '.github/spm-updater-config.json', dry_run: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: spm_updater.rb [--config path] [--dry-run]'
    opts.on('--config PATH', 'Path to project config JSON') { |v| options[:config] = v }
    opts.on('--dry-run', 'Print planned actions without changing anything') { options[:dry_run] = true }
  end.parse!
  options
end

OPTIONS = parse_options
# Graceful no-op when the consuming branch has no config yet: the wrapper
# workflow can land on the default branch ahead of the SPM migration itself
# (workflows only appear in the Actions UI once they exist there), and a
# scheduled run before the migration merges must not read as a failure.
unless File.exist?(OPTIONS[:config])
  warn "!! #{OPTIONS[:config]} not found — SPM updater is not configured on this branch, nothing to do"
  exit 0
end
CONFIG = JSON.parse(File.read(OPTIONS[:config]))

WORKSPACE       = CONFIG.fetch('workspace')
BRANCH_PREFIX   = CONFIG['branch_prefix'] || 'chore/spm-'
COMMIT_PREFIX   = CONFIG['commit_prefix'] || 'chore(spm):'
PR_LABELS       = CONFIG['pr_labels'] || %w[dependencies spm]
ADAPTERS_YML    = CONFIG['adapters_yml'] || 'fastlane/adapters.yml'
DEFERRED_PATH   = CONFIG['deferred_path'] || '.github/spm-deferred.json'
RESOLVE_SCHEMES = CONFIG['resolve_schemes'] || []
ADAPTERS_DIR    = CONFIG['adapters_dir'] || 'Adapters'
NETWORKS        = CONFIG.fetch('networks')

def default_branch
  ENV['PODS_BASE_BRANCH'] || CONFIG['base_branch'] || 'develop'
end

def repo_slug
  ENV['GITHUB_REPOSITORY'] || `git remote get-url origin`.strip[%r{github\.com[:/](.+?)(\.git)?$}, 1]
end

def api_token
  ENV['GITHUB_TOKEN'].to_s
end

def git_push_token
  ENV['PODS_UPDATER_TOKEN'].to_s.empty? ? api_token : ENV['PODS_UPDATER_TOKEN']
end

def dry_run?
  OPTIONS[:dry_run]
end

# --- Shell / git helpers ---

def sh!(cmd)
  puts ">> #{cmd}"
  return if dry_run?
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
  remote = "https://x-access-token:#{git_push_token}@github.com/#{owner}/#{repo}.git"
  return puts ">> [dry-run] git push #{branch}" if dry_run?
  ok = system("git push -u #{remote} HEAD:#{branch} --force-with-lease")
  unless ok
    system("git fetch origin #{branch}")
    sh!("git push -u #{remote} HEAD:#{branch} --force")
  end
end

# --- Remote version discovery ---

def http_get(url)
  cmd = ['curl', '-fsSL', '--retry', '3', '--retry-delay', '1', url]
  body = IO.popen(cmd, &:read)
  raise "curl failed for #{url}" unless $?.success?
  body
end

def http_get_json(url)
  JSON.parse(http_get(url))
end

# All version-looking tags of a GitHub repo, ascending.
def repo_tags(repo_url)
  @tags_cache ||= {}
  @tags_cache[repo_url] ||= begin
    out = IO.popen(['git', 'ls-remote', '--tags', repo_url], err: File::NULL, &:read)
    unless $?.success?
      # Fail soft: an unreachable/renamed repo must not kill the whole run, but
      # it MUST be loud — as a gate it reads as "closed" and silently blocks
      # updates for its network until the config is fixed.
      warn "!! git ls-remote failed for #{repo_url} — treating as no tags; check the config"
      []
    else
      out.lines
         .map { |l| l.split("\t").last.to_s.strip.sub('refs/tags/', '').sub(/\^\{\}$/, '') }
         .uniq
    end
  end
end

# Numeric tags (optionally v-prefixed), ascending by version.
def version_tags(repo_url)
  repo_tags(repo_url)
    .map { |t| t.sub(/^v/, '') }
    .select { |t| t =~ /^\d+(\.\d+)*$/ }
    .uniq
    .sort_by { |v| Gem::Version.new(v) }
end

def tag_for_version(repo_url, version, tag_style)
  prefix = tag_style == 'v-prefixed' ? 'v' : ''
  candidate = "#{prefix}#{version}"
  repo_tags(repo_url).include?(candidate) ? candidate : nil
end

def raw_manifest(repo_url, tag)
  slug = repo_url[%r{github\.com[:/](.+?)(\.git)?$}, 1]
  http_get("https://raw.githubusercontent.com/#{slug}/#{tag}/Package.swift")
end

# The `exact:` requirement a manifest declares for a dependency whose URL
# contains +dep_url_substring+.
def manifest_exact_pin(manifest, dep_url_substring)
  manifest[/\.package\(\s*url:\s*"[^"]*#{Regexp.escape(dep_url_substring)}[^"]*"\s*,\s*(?:\.exact\(\s*)?exact:?\s*[:(]?\s*"([^"]+)"/, 1] ||
    manifest[/\.package\(\s*url:\s*"[^"]*#{Regexp.escape(dep_url_substring)}[^"]*"\s*,\s*\.exact\("([^"]+)"\)/, 1]
end

# binaryTarget name => { url:, checksum: } pairs of a manifest.
def manifest_binary_targets(manifest)
  manifest.scan(/\.binaryTarget\(\s*name:\s*"([^"]+)"\s*,\s*url:\s*"([^"]+)"\s*,\s*checksum:\s*"([^"]+)"/m)
          .to_h { |name, url, checksum| [name, { url: url, checksum: checksum }] }
end

# AppLovin mediation adapter tags encode the network version in two-digit
# groups: 905000000.0.0 -> 9.5.0.0.0, of which the last two groups are the
# adapter's own revision — network version 9.5.0.
def decode_applovin_tag(tag)
  head = tag.split('.').first.to_s
  return nil unless head =~ /^\d+$/
  groups = []
  while head.length > 2
    groups.unshift(head[-2, 2].to_i)
    head = head[0..-3]
  end
  groups.unshift(head.to_i)
  return nil if groups.length < 3
  groups[0..-3].join('.')
end

# Does the MAX mediation adapter repo have a release for +sdk_version+?
def max_gate_open?(max_cfg, sdk_version)
  return true if max_cfg.nil? # no gate configured
  repo = max_cfg.fetch('repo')
  case max_cfg['tag_style'] || 'applovin_encoded'
  when 'applovin_encoded'
    repo_tags(repo).any? { |t| decode_applovin_tag(t) == sdk_version }
  else
    version_tags(repo).any? { |t| t == sdk_version || t.start_with?("#{sdk_version}.") }
  end
end

# The LevelPlay adapter tag whose manifest pins +sdk_version+, or nil.
#
# When +ironsource_dep_url_substring+ is configured, the tag is only eligible
# if its manifest references that IronSource package. IronSource switched
# their adapters from Unity-Mediation-iAds-Swift-Package to
# LevelPlay-Swift-Package mid-history; both wrap the same IronSourceSDK/LPSPM
# targets, so mixing generations in one workspace graph fails resolution with
# duplicate target names. The workspace's local override pins one generation —
# adapters that moved on are ineligible until the override moves with them.
def levelplay_tag_for(lp_cfg, sdk_version)
  repo = lp_cfg.fetch('repo')
  dep = lp_cfg.fetch('sdk_dep_url_substring')
  generation = lp_cfg['ironsource_dep_url_substring']
  version_tags(repo).reverse_each do |tag|
    manifest = raw_manifest(repo, tag) rescue next
    next unless manifest_exact_pin(manifest, dep) == sdk_version
    if generation && !manifest.include?(generation)
      puts ">> #{repo.split('/').last} #{tag} pins the right SDK but uses a different IronSource package generation — ineligible"
      next
    end
    return tag
  end
  nil
end

# The BidonAdapter pod version for +sdk_version+ (adapter versions are the SDK
# version plus a revision segment), or nil.
def bidon_version_for(pod, sdk_version)
  data = http_get_json("#{TRUNK_BASE}/#{URI.encode_www_form_component(pod)}") rescue nil
  return nil unless data
  versions = (data['versions'] || []).map { |x| x['name'] }.compact
  versions.select { |v| v == sdk_version || v.start_with?("#{sdk_version}.") }
          .max_by { |v| Gem::Version.new(v) }
end

# --- Pin editors ---

# Current exactVersion of a named XCRemoteSwiftPackageReference.
def pbxproj_current_pin(file, reference)
  src = File.read(file)
  block = src[/XCRemoteSwiftPackageReference "#{Regexp.escape(reference)}" \*\/ = \{.*?\};/m]
  raise "Package reference '#{reference}' not found in #{file}" unless block
  block[/version = ([0-9.]+);/, 1]
end

def pbxproj_set_pin(file, reference, to_version)
  src = File.read(file)
  changed = false
  new_src = src.gsub(/(XCRemoteSwiftPackageReference "#{Regexp.escape(reference)}" \*\/ = \{.*?version = )([0-9.]+)(;)/m) do
    changed = true
    "#{Regexp.last_match(1)}#{to_version}#{Regexp.last_match(3)}"
  end
  raise "Package reference '#{reference}' not found in #{file}" unless changed
  File.write(file, new_src) unless dry_run?
  puts ">> #{file}: #{reference} -> #{to_version}"
end

# Remove an SPM package (reference entry, packageReferences list line, product
# dependency entries and their uses on targets) from a pbxproj. Entries carry
# the reference name in their /* comments */, which Xcode maintains.
def pbxproj_remove_package(file, reference)
  src = File.read(file)
  # find product dependency ids that point at this package reference
  ref_id = src[/([0-9A-F]{24}) \/\* XCRemoteSwiftPackageReference "#{Regexp.escape(reference)}" \*\/ = \{/, 1]
  raise "Package reference '#{reference}' not found in #{file}" unless ref_id
  product_ids = src.scan(/([0-9A-F]{24}) \/\* [^*]+ \*\/ = \{\s*isa = XCSwiftPackageProductDependency;\s*package = #{ref_id} [^;]+;/m).flatten
  new_src = src.dup
  # entry blocks
  new_src.sub!(/\t\t#{ref_id} \/\* XCRemoteSwiftPackageReference "#{Regexp.escape(reference)}" \*\/ = \{.*?\n\t\t\};\n/m, '')
  product_ids.each do |pid|
    new_src.sub!(/\t\t#{pid} \/\* [^*]+ \*\/ = \{.*?\n\t\t\};\n/m, '')
  end
  # list lines
  ([ref_id] + product_ids).each do |id|
    new_src.gsub!(/^\t+#{id} \/\* [^*]+ \*\/,\n/, '')
  end
  File.write(file, new_src) unless dry_run?
  puts ">> #{file}: removed package #{reference} (#{product_ids.size} product dep(s))"
end

# Re-add an SPM package with a product on one target. IDs are deterministic
# (md5 of a stable seed) so repeated restore runs stay idempotent.
def pbxproj_add_package(file, reference, repo_url, version, target_name, product)
  src = File.read(file)
  ref_id  = Digest::MD5.hexdigest("ref:#{reference}")[0, 24].upcase
  prod_id = Digest::MD5.hexdigest("prod:#{reference}:#{product}")[0, 24].upcase
  raise "#{reference} already present in #{file}" if src.include?(ref_id)

  ref_entry = <<~ENTRY.gsub(/^/, "\t\t").chomp
    #{ref_id} /* XCRemoteSwiftPackageReference "#{reference}" */ = {
    \tisa = XCRemoteSwiftPackageReference;
    \trepositoryURL = "#{repo_url}";
    \trequirement = {
    \t\tkind = exactVersion;
    \t\tversion = #{version};
    \t};
    };
  ENTRY
  prod_entry = <<~ENTRY.gsub(/^/, "\t\t").chomp
    #{prod_id} /* #{product} */ = {
    \tisa = XCSwiftPackageProductDependency;
    \tpackage = #{ref_id} /* XCRemoteSwiftPackageReference "#{reference}" */;
    \tproductName = #{product};
    };
  ENTRY

  new_src = src.dup
  new_src.sub!('/* End XCRemoteSwiftPackageReference section */') { "#{ref_entry}\n/* End XCRemoteSwiftPackageReference section */" }
  new_src.sub!('/* End XCSwiftPackageProductDependency section */') { "#{prod_entry}\n/* End XCSwiftPackageProductDependency section */" }
  new_src.sub!(/(packageReferences = \(\n)/) { "#{Regexp.last_match(1)}\t\t\t\t#{ref_id} /* XCRemoteSwiftPackageReference \"#{reference}\" */,\n" }
  # target's packageProductDependencies
  target_re = /(name = #{Regexp.escape(target_name)};\n\t\t\tpackageProductDependencies = \(\n)/
  raise "Target #{target_name} has no packageProductDependencies list in #{file}" unless new_src =~ target_re
  new_src.sub!(target_re) { "#{Regexp.last_match(1)}\t\t\t\t#{prod_id} /* #{product} */,\n" }
  File.write(file, new_src) unless dry_run?
  puts ">> #{file}: added package #{reference} #{version} (product #{product} on #{target_name})"
end

# Sync a local override package manifest with the upstream manifest of the new
# tag: binaryTarget urls/checksums by target name, plus the version literal in
# the header comment and any occurrences of the old version in urls.
def local_manifest_sync(file, sdk_repo, tag, from_version, to_version)
  upstream = manifest_binary_targets(raw_manifest(sdk_repo, tag))
  src = File.read(file)
  updated = src.gsub(/\.binaryTarget\(\s*name:\s*"([^"]+)"\s*,\s*url:\s*"([^"]+)"\s*,\s*checksum:\s*"([^"]+)"/m) do
    name = Regexp.last_match(1)
    up = upstream[name]
    if up
      ".binaryTarget(\n            name: \"#{name}\",\n            url: \"#{up[:url]}\",\n            checksum: \"#{up[:checksum]}\""
    else
      Regexp.last_match(0)
    end
  end
  updated = updated.gsub(from_version, to_version)
  File.write(file, updated) unless dry_run?
  puts ">> #{file}: synced binary targets to #{tag}"
end

def local_manifest_current_pin(file)
  # by convention the header comment names the mirrored upstream version:
  # "Local override of <slug> (X.Y.Z)."
  File.read(file)[/Local override of [^(]+\((\d+(?:\.\d+)*)\)/, 1] ||
    raise("No upstream version marker in #{file} header")
end

# --- Podfile editors ---

def podfile_bump_pod(pod, to_version)
  src = File.read('Podfile')
  changed = false
  new_src = src.gsub(/^(\s*pod\s+["']#{Regexp.escape(pod)}["'])\s*(?:,\s*["'][^"']+["'])?/) do
    changed = true
    %(#{Regexp.last_match(1)}, '#{to_version}')
  end
  raise "Pod '#{pod}' not found in Podfile" unless changed
  File.write('Podfile', new_src) unless dry_run?
  puts ">> Podfile: #{pod} -> #{to_version}"
end

def podfile_comment_out_pod(pod)
  src = File.read('Podfile')
  changed = false
  new_src = src.gsub(/^(\s*)(pod\s+["']#{Regexp.escape(pod)}["'][^\n]*)$/) do
    changed = true
    "#{Regexp.last_match(1)}# #{Regexp.last_match(2)}"
  end
  raise "Pod '#{pod}' not found in Podfile" unless changed
  File.write('Podfile', new_src) unless dry_run?
  puts ">> Podfile: commented out #{pod}"
end

def podfile_restore_pod(pod, version)
  src = File.read('Podfile')
  changed = false
  new_src = src.gsub(/^(\s*)#\s*(pod\s+["']#{Regexp.escape(pod)}["'])[^\n]*$/) do
    changed = true
    %(#{Regexp.last_match(1)}#{Regexp.last_match(2)}, '#{version}')
  end
  unless changed
    warn "!! Commented pod '#{pod}' not found in Podfile — skipping restore"
    return false
  end
  File.write('Podfile', new_src) unless dry_run?
  puts ">> Podfile: restored #{pod} at #{version}"
  true
end

def podfile_has_active_pod?(pod)
  File.read('Podfile') =~ /^\s*pod\s+["']#{Regexp.escape(pod)}["']/
end

# --- adapters.yml pin_overrides sync ---

def adapters_yml_set_pin_override(key, to_version)
  src = File.read(ADAPTERS_YML)
  changed = false
  new_src = src.gsub(/^(\s*#{Regexp.escape(key)}:\s*")[^"]+(")$/) do
    changed = true
    "#{Regexp.last_match(1)}#{to_version}#{Regexp.last_match(2)}"
  end
  warn "pin_overrides key #{key} not found in #{ADAPTERS_YML}" unless changed
  File.write(ADAPTERS_YML, new_src) if changed && !dry_run?
  puts ">> #{ADAPTERS_YML}: pin_overrides #{key} -> #{to_version}" if changed
end

# --- Deferred store ---

def load_deferred
  File.exist?(DEFERRED_PATH) ? JSON.parse(File.read(DEFERRED_PATH)) : []
end

def save_deferred(entries)
  File.write(DEFERRED_PATH, JSON.pretty_generate(entries) + "\n") unless dry_run?
end

def defer!(entries, network:, stack:, dependency:, waiting_for:, note:)
  return entries if entries.any? { |e| e['network'] == network && e['stack'] == stack }
  entries << {
    'network' => network, 'stack' => stack, 'dependency' => dependency,
    'waiting_for_sdk' => waiting_for, 'since' => Time.now.utc.strftime('%Y-%m-%d'),
    'note' => note
  }
  puts ">> Deferred: #{stack}/#{dependency} until SDK #{waiting_for}"
  entries
end

# --- Adapter changelog (same format the pods updater writes) ---

def update_adapter_changelog(adapter_name, network, to_version)
  path = File.join(ADAPTERS_DIR, adapter_name, 'CHANGELOG.md')
  return unless File.exist?(path)
  content = File.read(path)
  marker = "* Updated to #{network} #{to_version}"
  return if content.include?(marker)
  lines = content.lines
  idx = lines.index { |l| l.start_with?('# Changelog') } || 0
  lines.insert(idx + 1, "\n## #{to_version}\n#{marker}\n")
  File.write(path, lines.join) unless dry_run?
end

# --- PR helpers (mirrors pods_updater.rb) ---

def open_pr_exists_for_branch?(branch)
  owner, repo = repo_slug.split('/', 2)
  uri = URI("https://api.github.com/repos/#{owner}/#{repo}/pulls?head=#{owner}%3A#{branch}&base=#{default_branch}&state=open")
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{api_token}"
    req['Accept'] = 'application/vnd.github+json'
    resp = http.request(req)
    return false unless resp.is_a?(Net::HTTPSuccess)
    arr = JSON.parse(resp.body)
    return arr.is_a?(Array) && !arr.empty?
  end
  false
end

def create_pr(branch, title, body)
  return puts ">> [dry-run] PR: #{title}" if dry_run?
  owner, repo = repo_slug.split('/', 2)
  uri = URI("https://api.github.com/repos/#{owner}/#{repo}/pulls")
  pr = nil
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{api_token}"
    req['Accept'] = 'application/vnd.github+json'
    req.body = { title: title, head: branch, base: default_branch, body: body, maintainer_can_modify: true }.to_json
    resp = http.request(req)
    raise "PR create failed: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)
    pr = JSON.parse(resp.body)
  end
  issues_uri = URI("https://api.github.com/repos/#{owner}/#{repo}/issues/#{pr['number']}/labels")
  req = Net::HTTP::Post.new(issues_uri)
  req['Authorization'] = "Bearer #{api_token}"
  req['Accept'] = 'application/vnd.github+json'
  req.body = { labels: PR_LABELS }.to_json
  Net::HTTP.start(issues_uri.host, issues_uri.port, use_ssl: true) { |http| http.request(req) }
  pr
end

# --- Gatekeeper cascade ---

def current_pin_for(net_cfg)
  pin = net_cfg.fetch('pin')
  case pin.fetch('type')
  when 'pbxproj'        then pbxproj_current_pin(pin.fetch('file'), pin.fetch('reference'))
  when 'local_manifest' then local_manifest_current_pin(pin.fetch('file'))
  else raise "Unknown pin type #{pin['type']}"
  end
end

def apply_own_pin(net_cfg, name, from_v, to_v)
  pin = net_cfg.fetch('pin')
  case pin.fetch('type')
  when 'pbxproj'
    pbxproj_set_pin(pin.fetch('file'), pin.fetch('reference'), to_v)
  when 'local_manifest'
    tag = tag_for_version(net_cfg.fetch('sdk_repo'), to_v, net_cfg['tag_style'])
    local_manifest_sync(pin.fetch('file'), net_cfg.fetch('sdk_repo'), tag || to_v, from_v, to_v)
  end
  adapters_yml_set_pin_override(net_cfg['adapters_yml_pin_override'], to_v) if net_cfg['adapters_yml_pin_override']
end

# Process one network. Returns a change summary string or nil.
def process_network(name, net_cfg, deferred)
  cur = current_pin_for(net_cfg)
  candidates = version_tags(net_cfg.fetch('sdk_repo'))
               .select { |v| Gem::Version.new(v) > Gem::Version.new(cur) }
  return nil if candidates.empty?

  # Walk candidates from the newest down; the MAX gate picks the version.
  target = candidates.reverse.find { |v| max_gate_open?(net_cfg['max_adapter'], v) }
  return nil if target.nil?

  gate = net_cfg['max_adapter'] ? 'MAX gate open' : 'no MAX gate configured'
  puts "\n== #{name}: #{cur} -> #{target} (#{gate})"
  summary = ["#{name} SDK #{cur} -> #{target}"]
  apply_own_pin(net_cfg, name, cur, target)
  Array(net_cfg['adapter']).each { |a| update_adapter_changelog(a, name, target) }

  pods_touched = false

  if (lp = net_cfg['levelplay_adapter'])
    lp_tag = levelplay_tag_for(lp, target)
    if lp_tag
      pbxproj_set_pin(lp.fetch('pin').fetch('file'), lp.fetch('pin').fetch('reference'), lp_tag)
      summary << "LevelPlay adapter -> #{lp_tag}"
    else
      pbxproj_remove_package(lp.fetch('pin').fetch('file'), lp.fetch('pin').fetch('reference'))
      defer!(deferred, network: name, stack: 'levelplay', dependency: lp.fetch('pin').fetch('reference'),
             waiting_for: target, note: 'No LevelPlay adapter tag pinning this SDK version yet')
      summary << 'LevelPlay adapter removed (deferred)'
    end
  end

  # Pods that mirror the SPM pin and must move in lockstep (a Podfile pin of
  # the same SDK kept for pod-built targets, e.g. the AdapterTests GMA pod).
  Array(net_cfg['extra_pods']).each do |pod|
    podfile_bump_pod(pod, target)
    summary << "pod #{pod} -> #{target}"
    pods_touched = true
  end

  if (bidon = net_cfg['bidon_adapter'])
    pod = bidon.fetch('pod')
    if podfile_has_active_pod?(pod)
      bidon_v = bidon_version_for(pod, target)
      if bidon_v
        podfile_bump_pod(pod, bidon_v)
        summary << "#{pod} -> #{bidon_v}"
      else
        podfile_comment_out_pod(pod)
        defer!(deferred, network: name, stack: 'bidon', dependency: pod,
               waiting_for: target, note: 'No BidonAdapter release for this SDK version yet')
        summary << "#{pod} commented out (deferred)"
      end
      pods_touched = true
    end
  end

  { summary: summary, pods_touched: pods_touched, target: target, from: cur }
end

# Restore pass: return entries that are still waiting; apply restores for the
# ones whose stack caught up.
def process_restores(deferred)
  still_waiting = []
  restored = []
  deferred.each do |entry|
    name = entry['network']
    net_cfg = NETWORKS[name]
    # Structural deferrals (e.g. a pod that would drag a duplicate SDK copy
    # back into the workspace) never auto-restore.
    if net_cfg.nil? || entry['restore'] == 'manual'
      still_waiting << entry
      next
    end
    cur = current_pin_for(net_cfg)
    case entry['stack']
    when 'levelplay'
      lp = net_cfg['levelplay_adapter']
      lp_tag = lp && levelplay_tag_for(lp, cur)
      if lp_tag
        pin = lp.fetch('pin')
        pbxproj_add_package(pin.fetch('file'), pin.fetch('reference'), "#{lp.fetch('repo')}.git",
                            lp_tag, lp.fetch('target_name'), lp.fetch('product'))
        restored << "#{entry['dependency']} (LevelPlay #{lp_tag})"
      else
        still_waiting << entry
      end
    when 'bidon'
      bidon_v = bidon_version_for(entry['dependency'], cur)
      if bidon_v && podfile_restore_pod(entry['dependency'], bidon_v)
        restored << "#{entry['dependency']} #{bidon_v}"
      else
        still_waiting << entry
      end
    else
      still_waiting << entry
    end
  end
  [still_waiting, restored]
end

# --- Main ---

def main
  git_reset_to_default unless dry_run?

  NETWORKS.each do |name, net_cfg|
    deferred = load_deferred
    # A pin that does not exist on this branch yet (partially merged migration)
    # skips the network instead of killing the whole run.
    begin
      branch_seed = process_network_branchless_probe(name, net_cfg)
    rescue => e
      warn "!! #{name}: #{e.message} — skipping"
      next
    end
    next unless branch_seed
    branch = "#{BRANCH_PREFIX}#{name}-#{branch_seed}"
    if open_pr_exists_for_branch?(branch)
      puts ">> Skipping #{name}: open PR for #{branch} already exists"
      next
    end
    unless dry_run?
      sh!("git fetch origin #{default_branch}")
      sh!("git checkout -B #{branch} origin/#{default_branch}")
    end

    begin
      result = process_network(name, net_cfg, deferred)
    rescue => e
      warn "!! #{name}: #{e.message} — resetting and moving on"
      @failures = (@failures || []) << name
      git_reset_to_default unless dry_run?
      next
    end
    next if result.nil?

    save_deferred(deferred)

    begin
      if result[:pods_touched]
        pod_bin = ENV['POD_BIN'] || 'pod'
        sh!("#{pod_bin} install")
      end
      RESOLVE_SCHEMES.each do |scheme|
        sh!("xcodebuild -resolvePackageDependencies -workspace #{WORKSPACE} -scheme #{scheme}")
      end
    rescue => e
      warn "!! #{name}: post-bump verification failed (#{e.message}) — resetting and moving on"
      @failures = (@failures || []) << name
      git_reset_to_default unless dry_run?
      next
    end

    msg = "#{COMMIT_PREFIX} #{name} #{result[:from]} -> #{result[:target]}"
    body_lines = result[:summary]
    unless dry_run?
      sh!('git add -A')
      sh!(%(git commit -m "#{msg}"))
      git_push_branch(branch)
      create_pr(branch, msg, <<~MD)
        SPM dependency update (gated cascade)

        #{body_lines.map { |l| "- #{l}" }.join("\n")}

        <!-- build-metadata
        #{JSON.pretty_generate({ network: name, from: result[:from], to: result[:target], adapters: Array(net_cfg['adapter']), changes: body_lines })}
        -->
      MD
      git_reset_to_default
    end
  end

  restore_pass

  if (@failures || []).any?
    warn "!! Networks that failed this run: #{@failures.join(', ')}"
    exit 1
  end
end

# Separate pass with its own branch/PR: restore deferred dependencies whose
# stack caught up with the currently pinned SDK versions.
def restore_pass
  deferred = load_deferred
  return if deferred.empty?
  branch = "#{BRANCH_PREFIX}restore-deferred"
  if open_pr_exists_for_branch?(branch)
    puts ">> Skipping restore pass: open PR for #{branch} already exists"
    return
  end
  unless dry_run?
    sh!("git fetch origin #{default_branch}")
    sh!("git checkout -B #{branch} origin/#{default_branch}")
  end
  still_waiting, restored = process_restores(deferred)
  if restored.empty?
    puts '>> Restore pass: nothing caught up yet'
    git_reset_to_default unless dry_run?
    return
  end
  save_deferred(still_waiting)
  pod_bin = ENV['POD_BIN'] || 'pod'
  sh!("#{pod_bin} install")
  RESOLVE_SCHEMES.each do |scheme|
    sh!("xcodebuild -resolvePackageDependencies -workspace #{WORKSPACE} -scheme #{scheme}")
  end
  msg = "#{COMMIT_PREFIX} restore deferred dependencies"
  unless dry_run?
    sh!('git add -A')
    sh!(%(git commit -m "#{msg}"))
    git_push_branch(branch)
    create_pr(branch, msg, <<~MD)
      Restore deferred dependencies whose mediation stack caught up

      #{restored.map { |r| "- #{r}" }.join("\n")}
    MD
    git_reset_to_default
  end
end

# Read-only probe: the target version this network would bump to (used for
# deterministic branch naming before any mutation happens).
def process_network_branchless_probe(name, net_cfg)
  cur = current_pin_for(net_cfg)
  candidates = version_tags(net_cfg.fetch('sdk_repo'))
               .select { |v| Gem::Version.new(v) > Gem::Version.new(cur) }
  return nil if candidates.empty?
  target = candidates.reverse.find { |v| max_gate_open?(net_cfg['max_adapter'], v) }
  if target.nil?
    puts ">> #{name}: #{candidates.last} available but MAX gate closed — skipping"
  end
  target
end

main
