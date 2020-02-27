# name: SOLR Indexing
# about: Index forum topics in Solr
# version: 0.2.0
# original author: Nate Flood for ECHO Inc
# original url: https://github.com/ECHOInternational/discourse-solr-indexing
# version authors: Rich Brennan & Alex Bridge for Torchbox
# version url: https://git.torchbox.com/sue-ryder/online-community/solr-plugin/

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
        # Expected schema format from Zoocha:
        #
        # - "id":"<DocumentID (a prefix would be good eg. TB:123, TB:1234)>",
        # - "ds_created":"<DateCreated>",
        # - "is_field_harmony_category":"<HarmonyID (appears to be the category)>",
        # - "tm_field_harmony_category$name":["<HarmonyName (appears to be the category)"],
        # ~ "ss_field_harmony_category$url":"<Link to category>",
        # - "dm_posts$created":["<Array of update times eg. 2019-05-24T07:31:13Z>",
        #   "<2019-05-24T12:18:16Z>",
        #   "<2019-05-25T06:08:58Z>",
        #   "<2019-05-25T22:18:54Z>",
        #   "<2019-05-25T22:34:28Z>"],
        # - "ss_search_api_language":"und",
        # "bs_status":"<boolean Is it published? This is actually optional. Ideally if something is deleted or unpublished an update should be pushed by torchbox to delete the index item>",
        # - "tm_title":["<post title>"],
        # - "tm_uid$name":["<username of poster>"],
        # - "ds_updated":"<Date of last update eg: 2019-05-25T22:34:28Z>",
        # - "ds_main_date":"<Date createdeg: 2019-05-25T22:34:28Z>",
        # - "ss_main_type":"Online Community Post",
        # - "tm_rendered_item":["<First post>",
        #   "<Reply1>",
        #   "<Reply2>",
        #   "<Remaining replies as array items>"],
        # - "ss_main_url":"<Full link to the thread>",
        # "bs_main_status":"<boolean Is it published? This is actually optional. Ideally if something is deleted or unpublished an update should be pushed by torchbox to delete the index item>"

        payload = {}

        payload[:id] = "ForumTopic_#{topic.id}"
        payload[:type] = "ForumTopic"
        payload["ds_created"] = topic.created_at
        payload["is_field_harmony_category"] = topic.category.id()
        payload["tm_field_harmony_category$name"] = topic.category.name()
        payload["ss_field_harmony_category$url"] = topic.category.url()
        payload["tm_uid$name"] = topic.user.username
        payload["ds_updated"] = topic.last_posted_at
        payload["ds_main_date"] = topic.created_at
        payload["ss_main_url"] = topic.url()
        payload["ss_search_api_language"] = "und"
        payload["tm_title"] = topic.title
        payload["ss_main_type"] = "Online Community Post"
        payload["bs_main_status"] = "true"
        payload["dm_posts$created"] = []
        payload["tm_rendered_item"] = []

        # Index only unhidden, undeleted replies
        topic.posts.where(hidden: false, deleted_at: nil).each do |post|
            payload["dm_posts$created"] << post.created_at
            payload["tm_rendered_item"] << post.cooked
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
          # Deleting by ss_main_type because deleting by type doesn't work
          SolrIndexing::SOLR.delete_by_query 'ss_main_type:"Online Community Post"'
          puts "SOLR Removing Records Completed"
        rescue
          puts "SOLR Removing Records Failed"
        end
        count = 0
        Category.where(read_restricted: false).each do | category |
          puts "SOLR Indexing #{category.name}"
          # Index only unhidden topics; the above query already excludes deleted ones
          category.topics.where(visible: true).each do |topic|
            serialized = SolrIndexing::Serializer.serialize_topic(topic)
            puts serialized
            SolrIndexing::SOLR.add serialized
            count = count+1
          end
        end
        puts "#{count} TOPICS INDEXED"
        puts "Solr Commit (soft)"
        # Use soft commit because Zoocha's config prevents hard commits
        SolrIndexing::SOLR.commit(params: { softCommit: true })
        puts "[SOLR REINDEX COMPLETED]"
      end
    end
  end

  def post_created(post, opts, user)
    return if !SiteSetting.solr_indexing_enabled
    # Don't index private forum topics
    return if !post.topic.category or (post.topic.category and post.topic.category.read_restricted) or post.topic.archetype = 'private_message'
    Jobs.enqueue(:solr_index_post, { post_id: post.id })
 	end
  listen_for :post_created

end

# curl http://my_solr:8983/solr/gettingstarted/select?q=*%3A*
# curl http://my_solr:8983/solr/update -H "Content-type: text/xml" --data-binary '<delete><query>*:*</query></delete>'
# curl http://my_solr:8983/solr/update -H "Content-type: text/xml" --data-binary '<commit />'
