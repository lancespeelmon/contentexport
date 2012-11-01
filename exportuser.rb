#!/usr/bin/env ruby

require 'rubygems'
require 'uri'
require 'net/http'
require 'net/https'
require 'json'

class LibraryExtractor

  def handleSakaiDoc(result)
    puts "I'm a doc!"
  end

  def handleFile(result)
    puts result
  end

  def handleCollection(result)
    puts "I'm a collection!"
  end

  def handleLink(result)
    puts "I'm a link!"
  end

  def extract(user, items, password)
    uri = URI("https://cole.uconline.edu/var/search/pool/auth-all.json?userid=#{user}&sortOn=_lastModified&sortOrder=desc&q=*&page=0&items=#{items}");
    response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth('admin', password)
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
  extractor = LibraryExtractor.new()
  extractor.extract('kdalex@ucdavis.edu', 500, ARGV[0])
end