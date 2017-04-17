Onebox = Onebox

module Onebox
  module Engine
    class SlackArchiveOnebox
      include Engine
      include LayoutSupport
      include JSON

      matches_regexp /^https?:\/\/(.*).slack.com\/archives\/(C.*)\/p(.*)$/
      always_https

      def url
        DiscourseSlack::API.history_url({
          channel: match[2],
          latest: match[3].insert(10, "."),
          count: 1,
          inclusive: true
        })
      end

      private

        def match
          @match ||= @url.match(/^https?:\/\/(.*).slack.com\/archives\/(C.*)\/p(.*)$/)
        end

        def data
          message = raw["messages"][0]

          text = message["text"]
          time = Time.at(message["ts"][0..10].to_i)
          timestamp = time.strftime("%-l:%M %p - %-d %b %Y")

          data = { link: @url,
                   text: text,
                   timestamp: timestamp,
                   attachments: message["attachments"]
                 }

          if message["user"].present?
            result = DiscourseSlack::API.user(message["user"])
            unless result["error"].present?
              user = result["user"]
              data["sender"] = user["name"]
              data["member_image"] = user["profile"]["image_48"] if user["profile"]["image_48"].present?
            end
          else
            data["sender"] = message["username"]
            data["member_image"] = "https://a.slack-edge.com/2fac/plugins/bot/assets/service_36.png"
          end

          data
        end
    end
  end
end
