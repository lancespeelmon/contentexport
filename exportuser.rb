#!/usr/bin/env ruby

require 'rubygems'
require 'uri'
require 'net/http'
require 'net/https'
require 'json'
require 'logger'

# MAXBYTES is max size before rotating log - set to 100 megabytes
$MAXBYTES = 100 * 1024 * 1024
$LOG = Logger.new('export.log', 0, $MAXBYTES)
# some incredibly huge number of items that ensures we get all content
$DFT_NUM_ITEMS = 500000

class LibraryExtractor

  attr_accessor :host, :userOutputDir, :user, :password
  host = "https://cole.uconline.edu"
  # top level output directory
  userOutputDir = nil
  # user id for library to export
  user = nil
  # admin password
  password = nil
  # tracks position in nested collections
  dirStack = nil
  # tracks index files of nested collections
  indexFileStack = nil
  # tracks the current collection we are exporting
  currentCollection = nil

  def initialize(user, password)
    @user = user
    @currentCollection = "Library of #{user}"
    @password = password
    @dirStack = []
    @indexFileStack = []

    # create a unique output directory
    now = Time.now
    outDirName = "output-#{now}"

    if !FileTest::directory?(outDirName)
      Dir::mkdir(outDirName)
    end

    userDir = outDirName + "/" + @user

    if !FileTest::directory?(userDir)
      Dir::mkdir(userDir)
    end

    @userOutputDir = Dir.new(userDir)

    $LOG.info("exporting data for #{@user} to: #{userDir}")

    # initialize the directory and index file stacks
    @dirStack.push @userOutputDir
    beginIndexFile
  end

  # get the current directory we are working on (ie. top of stack)
  def currentDir
    return @dirStack[@dirStack.length - 1]
  end

  # get the current index file we are working on (ie. top of stack)
  def currentIndexFile
    return @indexFileStack[@indexFileStack.length - 1]
  end

  # initialize the index file for the current directory
  # 'parent' is the name of the collection containing the current collection
  def beginIndexFile(parent = nil)
    indFile = File.new("#{currentDir().path}/index.html", "w")

    @indexFileStack.push indFile
    indFile.write("<html><body>")

    if !parent.nil?
      indFile.write("Parent: <a href=\"../index.html\">#{parent}</a>")
    end
    indFile.write("<ul>")
  end

  # close the current index file and adjust the stack
  def endIndexFile
    indFile = File.new("#{currentDir().path}/index.html", "w")
    indFile.write("</ul></body></html>")
    indFile.close()
    @indexFileStack.pop
  end

  def handleSakaiDoc(result)
    $LOG.info "sakaidoc skipped: #{result['_path']}"
  end

  # download a file from the library
  def handleFile(result)
    filename = result['sakai:pooled-content-file-name']
    path = result['_path']
    url = "#{@host}/p/#{path}/#{URI::encode(filename)}"
    currDir = currentDir()

    $LOG.info("downloading file from: #{url}")

    outputPath = currDir.path + "/" + filename

    # write the file pulled from the file url
    f = File.new(outputPath, "w")
    begin
        resp = getWithRedirects(url)
        $LOG.info("writing body to file")
        f.write(resp.body)
    ensure
        f.close()
    end

    currentIndexFile().write("<li>File: <a href=\"./#{filename}\">#{result['sakai:pooled-content-file-name']}</a></li>")
  end

  # obtain an HTTP response - handle HTTP redirects in the process
  def getWithRedirects (url)
    $LOG.info("getWithRedirects(\"#{url}\")")

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Get.new uri.request_uri
    request.basic_auth('admin', @password)

    response = http.request(request)

    if (response.kind_of?Net::HTTPRedirection)
      newUrl = nil
      if response['location'].nil?
          newUrl = response.body.match(/<a href=\"([^>]+)\">/i)[1]
      else
          newUrl = response['location']
      end

      $LOG.info("redirect encountered to url: #{newUrl}")

      return getWithRedirects(newUrl)
    end

    $LOG.info("returning HTTP response")
    return response
  end

  # handle a sub-collection
  def handleCollection(result)
    $LOG.debug("Collection: #{result}")
    currDir = currentDir()

    # keep track of the parent collection
    parent = @currentCollection

    begin
      collectionName = result['sakai:pooled-content-file-name']
      collectionPath = currDir.path + "/" + collectionName

      # set the current collection name
      @currentCollection = collectionName

      if !FileTest::directory?(collectionPath)
        Dir::mkdir(collectionPath)
      end

      collectionDir = Dir.new(collectionPath)

      # push to both the directory stack and the index file stack
      @dirStack.push collectionDir
      beginIndexFile (parent)

      # get the ID for the main page of the collection
      structure0 = JSON.parse(result['structure0'])
      refId = structure0['main']['_ref']
      $LOG.debug("refId: #{refId}")

      # pull the main page, then find the collectionviewer widget within it
      page = result[refId]
      $LOG.debug("page: #{page}")
      widgetref = page['rows']['__array__0__']['columns']['__array__0__']['elements']['__array__0__']

      # make sure we have a reference to a widget
      if !(widgetref['type'].nil?) and (widgetref['type'] == "collectionviewer")
        # now pull the widget data
        widgetId = widgetref['id']
        $LOG.debug("ID from collectionviewer widget ref: #{widgetId}")
        widget = page[widgetId]
        $LOG.debug("widget: #{widget}")

        # obtain the group ID we can use to export the collection
        groupId = widget['collectionviewer']['groupid']

        # export the collection
        export(groupId, $DFT_NUM_ITEMS)
      end
    ensure
      # no matter what happens, clean up the variables that maintain our context when we are done with this collection
      @dirStack.pop
      endIndexFile
      @currentCollection = parent
    end

    # add a link to the parent index file
    currentIndexFile().write("<li>Collection: <a href=\"./#{collectionName}/index.html\">#{collectionName}</a></li>")
  end

  # process a link from the collection
  def handleLink(result)
    link = nil
    if !result['sakai:pooled-content-url'].nil?
      link = result['sakai:pooled-content-url']
    else
      $LOG.error("no URL found in link: #{result}")
      return
    end

    # figure out if this is a link to OAE content
    link.scan(/#{@host}\/content#p=(.*)/) do |contentId|

      # obtain the content item and process it as if it had been included in the collection instead of linked
      $LOG.info "link has content id: #{contentId[0]}"
      uri = URI(@host + "/p/#{contentId[0]}.infinity.json");

      response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
        request = Net::HTTP::Get.new uri.request_uri
        request.basic_auth('admin', @password)
        response = http.request request
      end

      handleLibraryItem(JSON.parse(response.body))

      return
    end

    # if this is not OAE content, simply include the link in index file
    currentIndexFile().write("<li>Link: <a href=\"#{link}\">#{result['sakai:pooled-content-file-name']}</a></li>")
  end

  # process a single item from the library's content
  def handleLibraryItem(item)
    contentId = item['_path']
    uri = URI("#{@host}/p/#{contentId}.infinity.json")

    response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth('admin', @password)
      response = http.request request
    end

    json = JSON.parse(response.body)

    mimeType = json['_mimeType']
    if (mimeType == 'x-sakai/document')
      $LOG.info("sakai doc:[#{json['_path']}]")
      handleSakaiDoc json
    elsif (mimeType == 'x-sakai/collection')
      $LOG.info("collection:[#{json['_path']}]")
      handleCollection json
    elsif (mimeType == 'x-sakai/link')
      $LOG.info("link:[#{json['_path']}]")
      handleLink json
    else
      $LOG.info("file:[#{json['_path']}]")
      handleFile json
    end
  end

  # export a 'items' number of items from the library for user represented by 'id'
  def export(id, items)
    uri = URI(@host + "/var/search/pool/auth-all.json?userid=" + id +
                      "&sortOn=filename&sortOrder=desc&q=*&page=0&items=#{items}");

    response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth('admin', @password)
      response = http.request request
    end

    json = JSON.parse(response.body)
    results = json['results']

    results.each { |result|
      handleLibraryItem(result)
    }
  end

  # initial method to kick of processing of a user library
  def processLibrary
    export(@user, $DFT_NUM_ITEMS)
    endIndexFile
  end
end

if __FILE__ == $0
  extractor = LibraryExtractor.new(ARGV[0], ARGV[1])
  extractor.host = "https://cole.uconline.edu"
  extractor.processLibrary
end