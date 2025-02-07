#!/usr/bin/env bash
# exit on error
set -o errexit

# Install system dependencies
apt-get update -qq && apt-get install -y zbar-tools

# Build commands
bundle install
bundle exec rake assets:precompile
bundle exec rake assets:clean
bundle exec rake db:migrate