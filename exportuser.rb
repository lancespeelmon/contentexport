#!/usr/bin/env ruby

require 'rubygems'
require 'uri'
require 'net/http'
require 'net/https'
require 'json'

class LibraryExtractor

  attr_accessor :host, :userOutputDir, :user, :password
  host = "https://cole.uconline.edu"
  userOutputDir = nil
  user = nil
  password = nil

  def initialize(user, password)
    @user = user
    @password = password

    now = Time.now
    outDirName = "output-#{now}"
#    outDirName = "output"

    if !FileTest::directory?(outDirName)
      Dir::mkdir(outDirName)
    end

    userDir = outDirName + "/" + @user

    if !FileTest::directory?(userDir)
      Dir::mkdir(userDir)
    end

    @userOutputDir = Dir.new(userDir)
  end

  def handleSakaiDoc(result)
    puts "I'm a doc!"
  end

  def handleFile(result)
    filename = result['sakai:pooled-content-file-name']
    path = result['_path']
    url = "#{@host}/p/#{path}/#{URI::encode(filename)}"

    puts "downloading file from: #{url}"

    f = File.new(@userOutputDir.path + "/" + filename, "w")
    begin
        resp = getWithRedirects(url)
        f.write(resp.body)
    ensure
        f.close()
    end
  end

  def getWithRedirects (url)
    puts ("getting #{url}")
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Get.new uri.request_uri
    request.basic_auth('admin', @password)

    response = http.request(request)

    if (response.kind_of?Net::HTTPRedirection)
      puts "redirect encountered"
      newUrl = nil
      if response['location'].nil?
          newUrl = response.body.match(/<a href=\"([^>]+)\">/i)[1]
      else
          newUrl = response['location']
      end

      puts "new URL: #{newUrl}"
      return getWithRedirects(newUrl)
    end

    return response
  end

  def handleCollection(result)
    puts "I'm a collection!"
  end

  def handleLink(result)
    puts "I'm a link!"
  end

  def extract(items)
    uri = URI(@host + "/var/search/pool/auth-all.json?userid=" + @user +
                      "&sortOn=_lastModified&sortOrder=desc&q=*&page=0&items=#{items}");

    response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth('admin', @password)
      response = http.request request
    end

    json = JSON.parse(response.body)
    results = json['results']

    results.each { |result|

      mimeType = result['_mimeType']
      if (mimeType == 'x-sakai/document')
        handleSakaiDoc result
      elsif (mimeType == 'x-sakai/collection')
        handleCollection result
      elsif (mimeType == 'x-sakai/link')
        handleLink result
      else
        handleFile result
      end

    }

  end

end

if __FILE__ == $0
  extractor = LibraryExtractor.new(ARGV[0], ARGV[1])
  extractor.host = "https://cole.uconline.edu"
  extractor.extract(500)
end