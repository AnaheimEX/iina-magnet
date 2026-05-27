#!/usr/bin/env ruby
# iina-magnet-link.rb
#
# Links the local `iina-magnet/` Swift package into the iina Xcode target,
# so the AppDelegate hook can `import IinaMagnet`.
#
# Why a script (not a manual Xcode UI drag): keeping this edit reproducible
# means upstream merge conflicts can be re-applied deterministically by
# re-running this script after a sync (registered as hook H-006).
#
# Run from repo root: ruby other/iina-magnet-link.rb
#
# Requires: xcodeproj gem (`gem install --user-install xcodeproj`).

require 'xcodeproj'

PROJECT_PATH = 'iina.xcodeproj'
TARGET_NAME = 'iina'
PACKAGE_RELATIVE_PATH = 'iina-magnet'
PRODUCT_NAME = 'IinaMagnet'

project = Xcodeproj::Project.open(PROJECT_PATH)

target = project.targets.find { |t| t.name == TARGET_NAME }
abort "Target '#{TARGET_NAME}' not found" unless target

already_linked = target.package_product_dependencies.any? { |d| d.product_name == PRODUCT_NAME }
if already_linked
  puts "#{PRODUCT_NAME} already linked into #{TARGET_NAME}; nothing to do."
  exit 0
end

# Find or create the local package reference on the root project.
package_ref = project.root_object.package_references.find do |ref|
  ref.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
    ref.relative_path == PACKAGE_RELATIVE_PATH
end

unless package_ref
  package_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  package_ref.relative_path = PACKAGE_RELATIVE_PATH
  project.root_object.package_references << package_ref
  puts "Added local package reference: #{PACKAGE_RELATIVE_PATH}"
end

# Add the product dependency to the iina target.
product_ref = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product_ref.product_name = PRODUCT_NAME
product_ref.package = package_ref
target.package_product_dependencies << product_ref
puts "Linked product #{PRODUCT_NAME} to target #{TARGET_NAME}"

# Add to Frameworks build phase so the linker actually pulls it in.
frameworks_phase = target.frameworks_build_phase
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product_ref
frameworks_phase.files << build_file
puts "Added #{PRODUCT_NAME} to Frameworks build phase"

project.save
puts "Saved #{PROJECT_PATH}."
