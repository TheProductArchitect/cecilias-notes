#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the `CeciliasNotesShareExtension` target to the Xcode project.
#
# Uses the `xcodeproj` gem (the same library CocoaPods uses) for
# safe .pbxproj manipulation — proper isa types, file references,
# build phases, dependency edges, and the embed-into-host-app
# copy-files phase. If anything goes wrong, restore with
# `git restore CeciliasNotes/CeciliasNotes.xcodeproj/project.pbxproj`.
#
# Usage:
#   gem install xcodeproj          # one-time
#   cd CeciliasNotes/CeciliasNotesShareExtension
#   ruby add-target.rb
#
# After it runs, open Xcode and Build (⌘B) the CeciliasNotes scheme.
# The share extension target builds with the main app and embeds
# automatically.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../CeciliasNotes.xcodeproj', __dir__)
EXT_FOLDER   = File.expand_path(__dir__)
EXT_NAME     = 'CeciliasNotesShareExtension'
EXT_BUNDLE   = 'app.ceciliasnotes.share'
HOST_TARGET  = 'CeciliasNotes'
APP_GROUP    = 'group.app.ceciliasnotes'
TEAM_ID      = 'W9559HJWN9'
DEPLOYMENT   = '17.6'

abort "project not found at #{PROJECT_PATH}" unless File.exist?(PROJECT_PATH)

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.any? { |t| t.name == EXT_NAME }
  puts "✓ target '#{EXT_NAME}' already exists — nothing to do."
  exit 0
end

host = project.targets.find { |t| t.name == HOST_TARGET }
abort "host target '#{HOST_TARGET}' not found" unless host

# Create the extension target. `:app_extension` produces the right
# productType (com.apple.product-type.app-extension) and wires the
# standard build phases (sources, frameworks, resources).
ext = project.new_target(
  :app_extension,
  EXT_NAME,
  :ios,
  DEPLOYMENT
)

# Group for the extension folder (sibling of the main app group).
group = project.main_group.new_group(EXT_NAME, EXT_NAME, '<group>')

source_ref = group.new_reference('ShareViewController.swift')
plist_ref  = group.new_reference('Info.plist')
ents_ref   = group.new_reference("#{EXT_NAME}.entitlements")

ext.source_build_phase.add_file_reference(source_ref)

# Build settings — match the main app's signing style and team so
# automatic provisioning resolves the App Group entitlement on
# first build. Bundle ID derives from the main app's reverse-DNS
# prefix per Apple convention.
%w[Debug Release].each do |configuration_name|
  config = ext.build_configurations.find { |c| c.name == configuration_name }
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'         => EXT_BUNDLE,
    'PRODUCT_NAME'                      => "$(TARGET_NAME)",
    'INFOPLIST_FILE'                    => "#{EXT_NAME}/Info.plist",
    'CODE_SIGN_ENTITLEMENTS'            => "#{EXT_NAME}/#{EXT_NAME}.entitlements",
    'CODE_SIGN_STYLE'                   => 'Automatic',
    'DEVELOPMENT_TEAM'                  => TEAM_ID,
    'IPHONEOS_DEPLOYMENT_TARGET'        => DEPLOYMENT,
    'TARGETED_DEVICE_FAMILY'            => '1,2',
    'SWIFT_VERSION'                     => '5.0',
    'GENERATE_INFOPLIST_FILE'           => 'NO',
    'SKIP_INSTALL'                      => 'YES',
    'CURRENT_PROJECT_VERSION'           => '1',
    'MARKETING_VERSION'                 => '1.0',
    'LD_RUNPATH_SEARCH_PATHS'           => '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  )
end

# Embed the .appex inside the host app so it ships with the
# install. The "Embed App Extensions" copy-files phase has
# dstSubfolderSpec=13 (PlugIns) — Xcodeproj picks the right
# constant when we use `:plug_ins` shorthand.
embed_phase = host.copy_files_build_phases.find do |phase|
  phase.symbol_dst_subfolder_spec == :plug_ins
end
embed_phase ||= host.new_copy_files_build_phase('Embed App Extensions').tap do |phase|
  phase.symbol_dst_subfolder_spec = :plug_ins
end
embed_file = embed_phase.add_file_reference(ext.product_reference)
embed_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# Make sure the host depends on the extension so a clean build of
# the app builds the extension first.
host.add_dependency(ext)

project.save
puts "✓ target '#{EXT_NAME}' added."
puts "  bundle id: #{EXT_BUNDLE}"
puts "  next: open Xcode and Build the CeciliasNotes scheme (⌘B)."
puts "  if signing complains, open Signing & Capabilities on the new"
puts "  target and tick App Groups → #{APP_GROUP}."
