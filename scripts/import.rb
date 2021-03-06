#!/usr/bin/env ruby

rails_environment_path = File.expand_path(File.join(File.dirname(__FILE__), '..', 'config', 'environment'))

require rails_environment_path
require "redis"

# hack into #to_hash so we don't lose the attributes in thumbnails
# it's either this or using a more complex library like nokogiri
# see https://stackoverflow.com/questions/19309465/keeping-attributes-when-converting-xml-to-ruby-hash#29431089
module ActiveSupport
  class XMLConverter
    private
    def become_content?(value)
      value['type'] == 'file' || (value['__content__'] && (value.keys.size == 1 && value['__content__'].present?))
    end
  end
end

# adapted from https://gist.github.com/chris/b4138603a8fe17e073c6bc073eb17785
class Hash
  def deep_transform_values!(&block)
    self.transform_values! do |value|
      value.is_a?(Hash) ? value.deep_transform_values!(&block) : yield(value)
    end
  end
end

Rails.logger.info "Starting"

trap("INT") do
  puts "Script terminated by user"
  exit
end

redis_channel = "bigbluebutton:from-rap"
paths = [
  "/var/bigbluebutton/published/**/metadata.xml",
  "/var/bigbluebutton/unpublished/**/metadata.xml"
]

redis = Redis.new(host: ENV["BBB_REDIS_HOST"], port: ENV["BBB_REDIS_PORT"], db: ENV["BBB_REDIS_DB"])

Dir[*paths].each do|metadata_path|
  matched = metadata_path.match(/([^\/]+)\/([^\/]+)\/([^\/]+)\/metadata.xml$/)
  scope = matched[1]
  format = matched[2]
  record_id = matched[3]

  xml = File.open(metadata_path)
  metadata_xml = Hash.from_xml(xml)
  metadata_xml = metadata_xml["recording"]
  metadata_xml["playback"].deep_transform_keys!{ |key|
    if key == "__content__"
      "link"
    else
      key
    end
  }
  metadata_xml.deep_transform_values!{ |v| v.is_a?(String) ? v.strip : v }

  if scope == "unpublished"
    origin = File.dirname(metadata_path)
    destination = File.dirname(metadata_path).gsub(/unpublished/, 'published')
    Rails.logger.info "Moving #{origin} to #{destination}"
    FileUtils.mv(origin, destination)
  end

  event = {
    header: {
      timestamp: DateTime.now.to_i,
      name: "publish_ended",
      current_time: DateTime.now.to_i,
      version: "0.0.1"
    }, payload: {
      success: true,
      step_time: 0, # ?
      playback: metadata_xml["playback"],
      metadata: metadata_xml["meta"],
      start_time: metadata_xml["start_time"].to_i,
      end_time: metadata_xml["end_time"].to_i,
      participants: metadata_xml["participants"].to_i,
      raw_size: metadata_xml["raw_size"],
      workflow: format,
      external_meeting_id: metadata_xml["meta"]["meetingId"],
      published: metadata_xml["published"] == "true",
      record_id: record_id,
      meeting_id: record_id
    }
  }

  Rails.logger.info "Importing #{scope}/#{format}/#{record_id}"
  redis.publish redis_channel, event.to_json
end

Rails.logger.info "Ended"
