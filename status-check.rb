#!/usr/bin/ruby
require 'net/http'
require 'nokogiri'
require 'json'

def config_get(key)
  path = File.expand_path(File.dirname(File.dirname(__FILE__))) + "/config"
  if !File.exists?(path)
    $stderr.puts "Please adapt the config file first. It got generated in the directory of the script."

    config_template = "obs_user=
obs_password=
obs_project_link=
repos=
trello_api_key=
trello_api_token=
trello_card_id=
trello_cover_success_name=
trello_cover_error_name="

    File.open(path, "w").write(config_template)
    exit! 1
  end

  File.open(path).each_line do |line|
    pos = line.index('=')
    if pos != -1 && line[0..pos-1] == key
      value = line[pos+1..-1]
      value = value[0..value.length-2] if value[-1] == "\n"

      return value
    end
  end

  nil
end

api_uri = URI("https://api.opensuse.org/build/OBS:Server:Unstable/_result?multibuild=1&locallink=1&package=obs-server")
request = Net::HTTP::Get.new(api_uri)
request.basic_auth config_get('obs_user'), config_get('obs_password')

response = Net::HTTP.start(api_uri.hostname, api_uri.port, use_ssl: true) {|http|
  http.request(request)
}

resultlist = Nokogiri::XML(response.body)

status_list = []
resultlist.xpath('//resultlist/result').each do |result|
  code = result.xpath("./status").map {|element| element.attributes["code"].value if element.attributes["package"].value == "obs-server" }.first
  if code == "disabled"
    next
  end

  status_list.push({
    code:       code,
    repository: result.attributes["repository"].value,
    arch:       result.attributes["arch"].value
  })
end

repos = []
config_repos = config_get("repos")

config_repos.split(",").each do |repo|
  data = repo.split(":")
  repos.push({ repository: data[0], arch: data[1] })
end

package_status = true
skip_cover_update = false

trello_card_content = "Visit project: #{config_get("obs_project_link")}\n\n"

repos.each do |repo|
  status_list.each do |item|
    if item[:repository] == repo[:repository] && item[:arch] == repo[:arch]
      trello_card_content += "#{repo[:repository]} (#{repo[:arch]}): #{item[:code]}\n"

      if item[:code] == "scheduled" || item[:code] == "building"
        # don't update trello card cover if one of the packages is being built
        skip_cover_update = true
      end

      if item[:code] == "unresolvable" || item[:code] == "failed"
        package_status = false
      end
    end
  end
end

trello_card_id = config_get("trello_card_id")
trello_key = config_get("trello_api_key")
trello_token = config_get("trello_api_token")

if skip_cover_update == false
  attachment_uri = URI("https://api.trello.com/1/cards/#{trello_card_id}/attachments?key=#{trello_key}&token=#{trello_token}")
  request = Net::HTTP::Get.new(attachment_uri)
  response = Net::HTTP.start(attachment_uri.hostname, attachment_uri.port, use_ssl: true) {|http|
    http.request(request)
  }

  cover_file_name = config_get("trello_cover_success_name")
  cover_file_name = config_get("trello_cover_error_name") if package_status == false

  response = JSON.parse(response.body)
  cover_id = response.select {|image| image if image["name"] == cover_file_name }.first["id"]

  cover_uri = URI("https://api.trello.com/1/cards/#{trello_card_id}/idAttachmentCover?value=#{cover_id}&key=#{trello_key}&token=#{trello_token}")
  request = Net::HTTP::Put.new(cover_uri)
  response = Net::HTTP.start(cover_uri.hostname, cover_uri.port, use_ssl: true) {|http|
    http.request(request)
  }
end

card_desc_uri = URI("https://api.trello.com/1/cards/#{trello_card_id}/desc?key=#{trello_key}&token=#{trello_token}")
request = Net::HTTP::Put.new(card_desc_uri)
request.set_form_data({
  "value" => trello_card_content
})
response = Net::HTTP.start(card_desc_uri.hostname, card_desc_uri.port, use_ssl: true) {|http|
  http.request(request)
}

