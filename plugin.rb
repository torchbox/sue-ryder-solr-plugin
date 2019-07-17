# name: SOLR Indexing
# about: Index forum topics in Solr
# version: 0.1.0
# authors: Nate Flood for ECHO Inc
# url: https://github.com/ECHOInternational/discourse-solr-indexing

gem "rsolr", "2.2.1"

enabled_site_setting :solr_indexing_enabled

after_initialize do
	module ::SolrIndexing
    PLUGIN_NAME = "solr_indexing".freeze
    SOLR = RSolr.connect url: SiteSetting.solr_indexing_server

    solr_indexing_server = SiteSetting.solr_indexing_server
    puts "SOLR Indexing server #{solr_indexing_server}"

    class Serializer
      def self.serialize_topic(topic)
        payload = {}

        payload[:id] = "ForumTopic_#{topic.id}"
        payload[:type] = "ForumTopic"
        payload[:date] = topic.last_posted_at
        payload[:url] = topic.url()
        # payload[:languages] = nil
        # payload[:rating] = nil
        # payload[:regions] = nil
        # payload[:tags] = nil

        if topic_detected_lang = topic.posts.first.custom_fields['post_detected_lang']
          payload["name_#{topic_detected_lang}"] = topic.title
          payload["description_#{topic_detected_lang}"] = topic.excerpt
        else
          payload['name_en'] = topic.title
          payload['description_en'] = topic.excerpt
        end

        topic.posts.each do |post|
          if detected_lang = post.custom_fields['post_detected_lang']
            payload["body_#{detected_lang}"] = payload["body_#{detected_lang}"].to_s + ' ' + post.cooked
          else
            payload['body_en'] = payload['body_en'].to_s + ' ' + post.cooked
          end

          if post.custom_fields['translated_text']
            post.custom_fields['translated_text'].each do |locale, value|
              payload["body_#{locale}"] = payload["body_#{locale}"].to_s + ' ' + value
            end
          end
        end

        return payload
      end
    end

 	end

  require_dependency "jobs/base"
  module ::Jobs
    class SolrIndexPost < Jobs::Base
      sidekiq_options retry: 3

      def execute(args)
        if post = Post.find_by(id: args[:post_id])
          serialized = SolrIndexing::Serializer.serialize_topic(post.topic)
          SolrIndexing::SOLR.add serialized, add_attributes: { commitWithin: 10000}
        end
      end
    end

    class SolrReindexSearch < Jobs::Scheduled
      every 12.hours

      def execute(args)
        return if !SiteSetting.solr_indexing_enabled

        puts "[SOLR REINDEX STARTED]"
        begin
          puts "SOLR Removing Records Started"
          SolrIndexing::SOLR.delete_by_query 'type:ForumTopic'
          puts "SOLR Removing Records Completed"
        rescue
          puts "SOLR Removing Records Failed"
        end
        Category.where(read_restricted: false).each do | category |
          puts "SOLR Indexing #{category.name}"
          category.topics.each do |topic|
            serialized = SolrIndexing::Serializer.serialize_topic(topic)
            puts serialized
            SolrIndexing::SOLR.add serialized
          end
        end
        puts "Solr Commit"
        SolrIndexing::SOLR.commit
        puts "[SOLR REINDEX COMPLETED]"
      end
    end
  end

	def post_created(post, opts, user)
    return if !SiteSetting.solr_indexing_enabled
    # Don't index private forum topics
    return if post.topic.category.read_restricted
    Jobs.enqueue(:solr_index_post, { post_id: post.id })
 	end
  listen_for :post_created

end

# curl http://my_solr:8983/solr/gettingstarted/select?q=*%3A*
# curl http://my_solr:8983/solr/update -H "Content-type: text/xml" --data-binary '<delete><query>*:*</query></delete>'
# curl http://my_solr:8983/solr/update -H "Content-type: text/xml" --data-binary '<commit />'
