#!/usr/bin/env ruby
module SponsorUtils
  DESCRIPTION = <<-HEREDOC
  SponsorUtils: good-enough scrapers and detectors of FOSS sponsors.
    Default to run from project root directory; will find and
    parse all available foundation/sponsorship mappings.
  HEREDOC
  module_function
  require 'csv'
  require 'yaml'
  require 'json'
  require 'open-uri'
  require 'nokogiri'
  require 'date'
  require 'optparse'
  require_relative 'foundation_reporter'

  # NOTE OWASP parsing css may be fragile; relies on nth-of-type
  # TODO: Eclipse dom parsing:
  #   div.eclipsefdn-members-list ... a with href and title that has sponsor name
  #   Member page: div.member-detail a

  # Map all sponsorships to common-ish levels
  # - Ordinals are cash sponsorships in order
  # - 'inkind'* is services donations (primarily services, not cash)
  # - community is widely used as a separate level
  # - grants covers any sort of government/institution grants
  # TODO: Define a more rigorous and smaller set of categories,
  #   to map some unusual ones (cncf:enduser, etc.) to simpler ones
  SPONSOR_METALEVELS = %w[ first second third fourth fifth sixth seventh eighth community firstinkind secondinkind thirdinkind fourthinkind startuppartners academic enduser grants ]
  CURRENT_SPONSORSHIP = '20240101' # HACK: select current one TODO allow different dates/versions
  DEFAULT_OUTFILE = '_data/allsponsorships-new.json' # Default to producing report of everything

  # Return a normalized domain name for mapping to a single sponsor org
  # HACK note several special casees mapping down to single org
  # @return a good enough normalized hostname
  def normalize_href(href)
    begin
    return URI(href.strip.downcase.sub('www.', '')
      .sub('opensource.google', 'google.com')
      .sub('techatbloomberg.com', 'bloomberg.com')
      .sub('opensource.twosigma.com', 'twosigma.com')
      .sub('opensource.salesforce.com', 'salesforce.com')
      # TODO: consider removing ^cloud. from: google baidu tencent
      # TODO: consider removing ^aws. from amazon ^azure. from microsoft
      # TODO: consider removing ^group. from mercedes-benz
      # TODO: consider removing ^en. from various urls
      ).authority
    rescue StandardError => e
      return href
    end
  end

  # Scrape html sponsor listing defined by css selectors
  # @param io input stream of html to parse
  # @param sponsor level map of organization
  # @return hash of sponsors by approximate map-defined levels
  def scrape_bycss(io, sponsorship)
    sponsors = {}
    normalize = sponsorship.fetch('normalize', nil)
    cssmap = sponsorship['levels']
    doc = Nokogiri::HTML5(io)
    body = doc.xpath('/html/body')
    cssmap.each do | lvl, lvldata |
      sponsors[lvl] = []
      begin
        nodelist = body.css(lvldata['selector'])
        attr = lvldata['attr']
        nodelist.each do | node |
          if 'href'.eql?(attr) && normalize
            sponsors[lvl] << normalize_href(node[attr])
          else
            sponsors[lvl] << node[attr]
          end
        end
      rescue StandardError => e
        sponsors[lvl] << "ERROR: scrape_bycss(...#{lvl}): #{e.message}\n\n#{e.backtrace.join("\n\t")}"
      end
    end
    return sponsors
  end

  # Parse a CNCF style landscape.yml for a sponsor list
  # @param io input stream of YAML to parse
  # @param sponsor level map of organization
  # @return hash of sponsors by approximate map-defined levels
  def parse_landscape(io, sponsorship)
    category = sponsorship['landscape']
    landscape = YAML.safe_load(io, aliases: true)
    landscape = landscape['landscape'] # will be array
    landscape = landscape.select{ | h | category.eql?(h.fetch('name', '')) }
    groups = landscape.first.fetch('subcategories', nil)
    sponsors = {}
    if groups
      groups.each do | group |
        levelname = group['name']
        level = ''
        sponsorship['levels'].each do | lvl, h |
          if levelname.eql?(h.fetch('name', ''))
            level = lvl
            break
          end
        end
        sponsors[level] = []
        group['items'].each do | sponsor |
          sponsors[level] << normalize_href(sponsor.fetch('homepage_url', sponsor['name']))
        end
      end
    else
      sponsors['error'] = "ERROR: parse_landscape(... #{category}) not found"
    end
    return sponsors
  end

  # Cleanup sponsor lists that are IDs not domains
  # @param sponsors hash of detected sponsor ids
  # @param filename of json mapping to read
  # @return sponsors hash normalized to domain names
  def cleanup_with_map(links, mapname)
    sponsors = {}
    map = JSON.parse(File.read(mapname))
    links.each do | level, ary |
      sponsors[level] = []
      ary.each do | itm |
        newitm = map.fetch(itm, nil)
        newitm ? sponsors[level] << newitm : sponsors[level] << normalize_href(itm)
      end
    end
    return sponsors
  end

  DRUPAL_SPONSOR_CSS = '.org-link a' # Sponsor is kept on a separate page
  DRUPAL_SPONSOR_URL = 'https://www.drupal.org'
  # Cleanup drupal sponsor list, since they use separate files
  # @param sponsors hash of detected sponsor links
  # @return sponsors hash normalized to domain names
  def cleanup_drupal(links)
    sponsors = {}
    links.each do | level, ary |
      sponsors[level] = []
      ary.each do | itm |
        begin
          doc = Nokogiri::HTML5(URI.open("#{DRUPAL_SPONSOR_URL}#{itm}").read)
          node = doc.at_css(DRUPAL_SPONSOR_CSS)
          if node
            sponsors[level] << normalize_href(node['href'])
          else
            sponsors[level] << itm
          end
        rescue StandardError => e
          sponsors[level] << "ERROR: cleanup_drupal(...#{itm}): #{e.message}\n\n#{e.backtrace.join("\n\t")}"
        end
      end
    end
    return sponsors
  end

  # Parse separate per-sponsor pages used by some orgs
  # @param sponsors hash of previously detected sponsor links
  # @param sponsorship definition hash
  # @return sponsors hash normalized to domain names
  def parse_subpages(existing_sponsors, sponsorship)
    sponsors = {}
    rooturl = sponsorship['sponsorroot']
    selector = sponsorship['sponsorselector']
    existing_sponsors.each do | level, ary |
      next unless ary.is_a?(Array) # Skip dates, errors, etc
      sponsors[level] = []
      ary.each do | itm |
        # Either store a normalized URL if present, or go parse the subpage
        if itm.downcase.start_with?('http')
          sponsors[level] << itm
        else
          begin
            doc = Nokogiri::HTML5(URI.open("#{rooturl}#{itm}").read)
            node = doc.at_css(selector)
            if node
              sponsors[level] << normalize_href(node['href'])
            else
              sponsors[level] << itm
            end
          rescue StandardError => e
            sponsors[level] << "ERROR: parse_subpages(...#{itm}): #{e.message}\n\n#{e.backtrace.join("\n\t")}"
          end
        end
      end
    end
    return sponsors
  end

  # Future use: allow parsing historical sponsorships
  def get_current_sponsorship(sponsorship)
    return sponsorship[CURRENT_SPONSORSHIP]
  end

  # Process single sponsorship maps
  # Includes special casing for specific orgs with unusual parsing
  # @param org id of org being parsed
  # @param sponsorship parsed _sponsorship hash defining what to do
  # @return processed hash of sponsors
  def parse_sponsorship(org, sponsorship)
    io = nil
    sponsors = {}
    sponsorurl = sponsorship['sponsorurl']
    begin
      io = URI.open(sponsorurl).read
    rescue StandardError => e
      sponsors['error'] = "ERROR: parse_sponsorship(#{sponsorurl}): #{e.message}\n\n#{e.backtrace.join("\n\t")}"
      return sponsors
    end
    # Parse a landscape.yml, or scrape a webpage by css
    if sponsorship.fetch('landscape', nil)
      sponsors = SponsorUtils.parse_landscape(io, sponsorship)
    else
      sponsors = SponsorUtils.scrape_bycss(io, sponsorship)
    end
    # Custom post-processing for various orgs
    subpage = sponsorship.fetch('sponsorselector', nil)
    if subpage
      sponsors = SponsorUtils.parse_subpages(sponsors, sponsorship)
    end
    mapping = sponsorship.fetch('sponsormap', nil)
    if mapping
      sponsors = SponsorUtils.cleanup_with_map(sponsors, mapping)
    end
    return sponsors
  end

  # Process a list of sponsorship maps
  # Includes special casing for specific orgs with unusual parsing
  # @param sponsorships array org => of _sponsorship hashes
  # @return hash of orgs = {sponsors...}
  def parse_sponsorships(sponsorships)
    parse_date = DateTime.now.strftime('%Y%m%d')
    all_sponsors = {}
    sponsorships.each do | org, sponsorship |
      all_sponsors[org] = parse_sponsorship(org, get_current_sponsorship(sponsorship))
      all_sponsors[org]['parseDate'] = parse_date
    end
    return all_sponsors
  end

  # Convenience method; assumes run from project root
  def parse_all_sponsorships()
    foundations = FoundationReporter.get_foundations('_foundations')
    sponsorships = {}
    foundations.each do | org, foundation |
      sponsorship = foundation.fetch('sponsorship', nil)
      if sponsorship
        sponsorships[org] = get_sponsorship_file(sponsorship)
      end
    end
    sponsorships['cncf'] = get_sponsorship_file('cncf') # HACK: Add in cncf as a test subject, since it's not a separate org
    all_sponsors = parse_sponsorships(sponsorships)
    return all_sponsors
  end

  # Convenience method to get a sponsorship file by org id
  def get_sponsorship_file(org)
    return JSON.parse(File.read("_sponsorships/#{org}.json"))
  end

  # ## ### #### ##### ######
  # Check commandline options
  def parse_commandline
    options = {}
    OptionParser.new do |opts|
      opts.on('-h', '--help') { puts "#{DESCRIPTION}\n#{opts}"; exit }
      opts.on('-oOUTFILE', '--out OUTFILE', 'Output filename for operation.') do |out|
        options[:out] = out
      end
      opts.on('-oORGID', '--one ORGID', 'Input org id (asf, python, etc.) to parse one.') do |orgid|
        options[:orgid] = orgid
      end
      begin
        opts.parse!
      rescue OptionParser::ParseError => e
        $stderr.puts e
        $stderr.puts opts
        exit 1
      end
    end
    return options
  end

  # ### #### ##### ######
  # Main method for command line use
  if __FILE__ == $PROGRAM_NAME
    options = parse_commandline
    orgid = options.fetch(:orgid, nil)
    parsed = {}
    if orgid
      options[:outfile] ||= "_data/#{orgid}-new.json"
      parsed = parse_sponsorship(orgid, get_current_sponsorship(get_sponsorship_file(orgid)))
    else
      options[:outfile] ||= DEFAULT_OUTFILE
      parsed = parse_all_sponsorships()
    end
    File.open(options[:outfile], "w") do |f|
      f.write(JSON.pretty_generate(parsed))
    end
  end
end