module DiscourseSlack
  class Slack
    KEY_PREFIX = 'category_'.freeze

    def self.filter_to_present(filter)
      I18n.t("slack.command.present.#{filter}")
    end

    def self.filter_to_past(filter)
      I18n.t("slack.command.past.#{filter}")
    end

    def self.excerpt(html, max_length)
      doc = Nokogiri::HTML.fragment(html)
      doc.css(".lightbox-wrapper .meta").remove
      html = doc.to_html

      SlackParser.get_excerpt(html, max_length)
    end

    def self.format_channel(name)
      (name.include?("@") || name.include?("\#"))? name : "<##{name}>"
    end

    def self.status
      rows = PluginStoreRow.where(plugin_name: DiscourseSlack::PLUGIN_NAME).where("key ~* :pat", :pat => '^category_.*')
      text = ""

      categories = rows.map { |item| item.key.gsub('category_', '') }

      Category.where(id: categories).each do | category |
        get_store(category.id).each do |row|
          tag_list = row['tags'].present? ? row['tags'].join(', ') : ""
          text << I18n.t("slack.message.status.category",
                          channel: format_channel(row[:channel]),
                          command: filter_to_present(row[:filter]),
                          name: category.name,
                          tags: tag_list)
        end
      end

      get_store.each do |row|
        tag_list = row['tags'].present? ? row['tags'].join(', ') : ""
        text << I18n.t("slack.message.status.all_categories",
                        channel: format_channel(row[:channel]),
                        command: filter_to_present(row[:filter]),
                        tags: tag_list)
      end
      cat_list = (CategoryList.new(guardian).categories.map { |category| category.slug }).join(', ')
      text << I18n.t("slack.message.available_categories", list: cat_list)
      text
    end

    def self.guardian
      Guardian.new(User.find_by(username: SiteSetting.slack_discourse_username))
    end

    def self.help
      I18n.t("slack.help")
    end

    def self.slack_message(post, channel)
      display_name = "@#{post.user.username}"
      full_name = post.user.name || ""

      if !(full_name.strip.empty?) && (full_name.strip.gsub(' ', '_').casecmp(post.user.username) != 0) && (full_name.strip.gsub(' ', '').casecmp(post.user.username) != 0)
        display_name = "#{full_name} @#{post.user.username}"
      end

      topic = post.topic

      category = (topic.category.parent_category) ? "[#{topic.category.parent_category.name}/#{topic.category.name}]": "[#{topic.category.name}]"

      icon_url =
        if !SiteSetting.slack_icon_url.blank?
          SiteSetting.slack_icon_url
        elsif !SiteSetting.logo_small_url.blank?
          "#{Discourse.base_url}#{SiteSetting.logo_small_url}"
        end

      message = {
        channel: channel,
        username: SiteSetting.title,
        icon_url: icon_url,
        attachments: []
      }

      summary = {
        fallback: "#{topic.title} - #{display_name}",
        author_name: display_name,
        author_icon: post.user.small_avatar_url,
        color: "##{topic.category.color}",
        text: ::DiscourseSlack::Slack.excerpt(post.cooked, SiteSetting.slack_discourse_excerpt_length),
        mrkdwn_in: ["text"]
      }

      record = ::PluginStore.get(DiscourseSlack::PLUGIN_NAME, "topic_#{post.topic.id}_#{channel}")

      if (SiteSetting.slack_access_token.empty? || post.is_first_post? || record.blank? || (record.present? &&  ((Time.now.to_i - record[:ts].split('.')[0].to_i)/ 60) >= 5 ))
        summary[:title] = "#{topic.title} #{(category == '[uncategorized]')? '' : category} #{topic.tags.present? ? topic.tags.map(&:name).join(', ') : ''}"
        summary[:title_link] = post.full_url
        summary[:thumb_url] = post.full_url
      end

      message[:attachments].push(summary)
      message
    end

    def self.get_key(id = nil)
      "#{KEY_PREFIX}#{id.present? ? id : '*'}"
    end

    def self.set_filter_by_id(id, channel, filter, tags = nil, channel_id = nil)
      data = get_store(id)
      tags = Tag.where(name: tags).pluck(:name)
      tags = nil if tags.blank?

      index = data.index do |filter|
        filter["channel"] == channel || filter["channel"] == channel_id
      end

      if index
        data[index]['filter'] = filter
        data[index]['channel'] = channel
        data[index]['tags'] = tags
      else
        data.push(channel: channel, filter: filter, tags: tags)
      end

      PluginStore.set(DiscourseSlack::PLUGIN_NAME, get_key(id), data)
    end

    def self.delete_filter(id, channel, tags)
      data = get_store(id)
      tags = nil if tags.blank?

      data.delete_if do |i|
        i['channel'] == channel && i['tags'] == tags
      end

      if data.empty?
        PluginStore.remove(DiscourseSlack::PLUGIN_NAME, get_key(id))
      else
        PluginStore.set(DiscourseSlack::PLUGIN_NAME, get_key(id), data)
      end
    end

    def self.get_store(id = nil)
      PluginStore.get(DiscourseSlack::PLUGIN_NAME, get_key(id)) || []
    end

    def self.notify(id)
      post = Post.find_by(id: id)
      return if post.blank?

      topic = post.topic
      return if post.topic.blank? && (post.topic.archetype == Archetype.private_message || post.post_type != Post.types[:regular])

      http = Net::HTTP.new(SiteSetting.slack_access_token.empty? ? "hooks.slack.com" : "slack.com" , 443)
      http.use_ssl = true

      precedence = { 'mute' => 0, 'watch' => 1, 'follow' => 1 }

      uniq_func = proc { |i| i.values_at(:channel, :tags) }
      sort_func = proc { |a, b| precedence[a] <=> precedence[b] }

      items = get_store(topic.category_id) | get_store
      responses = []

      items.sort_by(&sort_func).uniq(&uniq_func).each do |i|
        topic_tags = (SiteSetting.tagging_enabled? && topic.tags.present?) ? topic.tags.pluck(:name) : []

        next if SiteSetting.tagging_enabled? && i[:tags].present? && (topic_tags & i[:tags]).count == 0
        next if ( i[:filter] == 'mute') || ( !(post.is_first_post?) && i[:filter] == 'follow' )

        message = slack_message(post, i[:channel])

        if !(SiteSetting.slack_access_token.empty?)
          response = nil
          uri = ""
          record = ::PluginStore.get(DiscourseSlack::PLUGIN_NAME, "topic_#{post.topic.id}_#{i[:channel]}")

          if (record.present? && ((Time.now.to_i - record[:ts].split('.')[0].to_i)/ 60) < 5 && record[:message][:attachments].length < 5)
            attachments = record[:message][:attachments]
            attachments.concat message[:attachments]

            uri = URI("https://slack.com/api/chat.update" +
              "?token=#{SiteSetting.slack_access_token}" +
              "&username=#{CGI::escape(record[:message][:username])}" +
              "&text=#{CGI::escape(record[:message][:text])}" +
              "&channel=#{record[:channel]}" +
              "&attachments=#{CGI::escape(attachments.to_json)}" +
              "&ts=#{record[:ts]}"
            )
          else
            uri = URI("https://slack.com/api/chat.postMessage" +
              "?token=#{SiteSetting.slack_access_token}" +
              "&username=#{CGI::escape(message[:username])}" +
              "&icon_url=#{CGI::escape(message[:icon_url])}" +
              "&channel=#{ message[:channel].gsub('#', '') }" +
              "&attachments=#{CGI::escape(message[:attachments].to_json)}"
            )
          end

          response = http.request(Net::HTTP::Post.new(uri))

          ::PluginStore.set(DiscourseSlack::PLUGIN_NAME, "topic_#{post.topic.id}_#{i[:channel]}", JSON.parse(response.body) )
        elsif !(SiteSetting.slack_outbound_webhook_url.empty?)
          req = Net::HTTP::Post.new(URI(SiteSetting.slack_outbound_webhook_url), 'Content-Type' =>'application/json')
          req.body = message.to_json
          response = http.request(req)
        end

        responses.push(response.body) if response
      end

      responses
    end

    def self.channels
      return [] if SiteSetting.slack_access_token.empty?

      @channels = Rails.cache.fetch("slack_channels", expires_in: 15.minutes) do
        http = DiscourseSlack::API.http

        uri = URI("https://slack.com/api/channels.list?token=%{token}" % {
            token: SiteSetting.slack_access_token
          })

        response = http.request(Net::HTTP::Get.new(uri))

        if response && response.code == "200"
          JSON.parse(response.body)["channels"]
        else
          []
        end
      end

      @channels
    end

    def self.messages(channel_name, count)
      return { "error": I18n.t('slack.errors.access_token_is_empty') } if SiteSetting.slack_access_token.empty?

      #channel = channels.find { |c| c["name"] == channel_name }

      #return { "error": I18n.t('slack.errors.channel_not_found') } unless channel.present?

      return DiscourseSlack::API.message(channel_name, count)
    end
  end
end
