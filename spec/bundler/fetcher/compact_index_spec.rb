# frozen_string_literal: true

# load CompactIndexClient upfront to prevent thread safety issues during parallel specs
require "bundler/compact_index_client"

RSpec.describe Bundler::Fetcher::CompactIndex do
  let(:response) { double(:response) }
  let(:downloader) { double(:downloader, fetch: response) }
  let(:display_uri) { Gem::URI("http://sampleuri.com") }
  let(:remote)      { double(:remote, cache_slug: "lsjdf", uri: display_uri) }
  let(:gem_remote_fetcher) { nil }
  let(:compact_index) { described_class.new(downloader, remote, display_uri, gem_remote_fetcher) }
  let(:compact_index_client) { double(:compact_index_client, available?: true, info: [["lskdjf", "1", nil, [], []]]) }

  before do
    allow(response).to receive(:is_a?).with(Gem::Net::HTTPNotModified).and_return(true)
    allow(compact_index).to receive(:log_specs) {}
    allow(compact_index).to receive(:compact_index_client).and_return(compact_index_client)
  end

  describe "#cache_path" do
    context "when disable_compact_index_cache is not set" do
      before do
        allow(Bundler.settings).to receive(:[]).and_return(nil)
        allow(Bundler.settings).to receive(:[]).with(:disable_compact_index_cache).and_return(false)
      end

      it "returns the persistent user cache path" do
        persistent_path = Pathname.new("/home/user/.bundle/cache")
        allow(Bundler).to receive(:user_cache).and_return(persistent_path)

        expect(compact_index.send(:cache_path)).to eq(persistent_path.join("compact_index", "lsjdf"))
      end
    end

    context "when disable_compact_index_cache is set" do
      let(:tmp_path) { Pathname.new(Dir.mktmpdir) }

      before do
        allow(Bundler.settings).to receive(:[]).and_return(nil)
        allow(Bundler.settings).to receive(:[]).with(:disable_compact_index_cache).and_return(true)
        allow(Bundler).to receive(:tmp).and_return(tmp_path)
      end

      after { FileUtils.rm_rf(tmp_path) }

      it "returns a temporary directory" do
        expect(compact_index.send(:cache_path)).to eq(tmp_path)
      end

      it "does not use the persistent user cache" do
        persistent_path = Pathname.new("/home/user/.bundle/cache")
        allow(Bundler).to receive(:user_cache).and_return(persistent_path)

        expect(compact_index.send(:cache_path)).not_to start_with(persistent_path.to_s)
      end

      it "registers a finalizer to clean up the temporary directory" do
        expect(ObjectSpace).to receive(:define_finalizer).with(compact_index, anything)
        compact_index.send(:cache_path)
      end

      it "memoizes the temp path so the same directory is reused within a session" do
        expect(Bundler).to receive(:tmp).once.and_return(tmp_path)
        2.times { compact_index.send(:cache_path) }
      end
    end
  end

  describe "#specs_for_names" do
    let(:thread_list) { Thread.list.select {|thread| thread.status == "run" } }
    let(:thread_inspection) { thread_list.map {|th| "  * #{th}:\n    #{th.backtrace_locations.join("\n    ")}" }.join("\n") }

    it "has only one thread open at the end of the run" do
      compact_index.specs_for_names(["lskdjf"])

      thread_count = thread_list.count
      expect(thread_count).to eq(1), "Expected 1 active thread after `#specs_for_names`, but found #{thread_count}. In particular, found:\n#{thread_inspection}"
    end

    it "calls worker#stop during the run" do
      expect_any_instance_of(Bundler::Worker).to receive(:stop).at_least(:once).and_call_original

      compact_index.specs_for_names(["lskdjf"])
    end

    describe "#available?" do
      it "returns true" do
        expect(compact_index).to be_available
      end

      context "when OpenSSL is not available" do
        before do
          allow(compact_index).to receive(:require).with("openssl").and_raise(LoadError)
        end

        it "returns true" do
          expect(compact_index).to be_available
        end
      end

      context "when OpenSSL is FIPS-enabled" do
        def remove_cached_md5_availability
          return unless Bundler::SharedHelpers.instance_variable_defined?(:@md5_available)
          Bundler::SharedHelpers.remove_instance_variable(:@md5_available)
        end

        before do
          remove_cached_md5_availability
          stub_const("OpenSSL::OPENSSL_FIPS", true)
        end

        after { remove_cached_md5_availability }

        context "when FIPS-mode is active" do
          before do
            allow(OpenSSL::Digest).to receive(:digest).with("MD5", "").
              and_raise(OpenSSL::Digest::DigestError)
          end

          it "returns false" do
            expect(compact_index).to_not be_available
          end
        end

        it "returns true" do
          expect(compact_index).to be_available
        end
      end
    end

    context "logging" do
      before { allow(compact_index).to receive(:log_specs).and_call_original }

      context "with debug on" do
        before do
          allow(Bundler).to receive_message_chain(:ui, :debug?).and_return(true)
        end

        it "should log at info level" do
          expect(Bundler).to receive_message_chain(:ui, :debug).with('Looking up gems ["lskdjf"]')
          compact_index.specs_for_names(["lskdjf"])
        end
      end

      context "with debug off" do
        before do
          allow(Bundler).to receive_message_chain(:ui, :debug?).and_return(false)
        end

        it "should log at info level" do
          expect(Bundler).to receive_message_chain(:ui, :info).with(".", false)
          compact_index.specs_for_names(["lskdjf"])
        end
      end
    end
  end
end
