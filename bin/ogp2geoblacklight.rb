#!/usr/bin/env ruby
#
# Usage: transform_ogp output.json
#
#  Reads data/valid*.json in current directory
#

require 'awesome_print'
require 'json'
require 'uri'
require 'date'
require 'nokogiri'

# Transforms an OGP schema into GeoBlacklight. Requires input of a JSON array
# of OGP hashs.
class TransformOgp

  def initialize(fn)
    @output = File.open(fn, 'wb')
    @output.write "[\n"
    @fgdcdir = 'fgdc'
    yield self
    self.close
  end
  
  # @param [String|Array] s the URI to clean up
  # @return [String] a normalized URI
  def clean_uri(s)
    unless s.nil? or s.empty?
      return (s.is_a?(Array) ? URI(s.first) : URI(s)).to_s
    end
    ''
  end

  # @param [String] fn filename of JSON array of OGP hash objects
  # @return [Hash] stats about :accepted vs. :rejected records
  def transform_file(fn, skip_fgdc = false)
    stats = { :accepted => 0, :rejected => 0 }
    puts "Parsing #{fn}"
    json = JSON::parse(File.open(fn, 'rb').read)
    json.each do |doc| # contains JSON Solr query results
      unless doc.empty?
        begin
          transform(doc, skip_fgdc)
          stats[:accepted] += 1
        rescue ArgumentError => e
          puts e
          stats[:rejected] += 1
        end
      end
    end
    stats
  end

  # Transforms a single OGP record into a GeoBlacklight record
  # @param [Hash] layer an OGP hash for a given layer
  def transform(layer, skip_fgdc = false)
    id = layer['LayerId'].to_s.strip
    puts "Tranforming #{id} #{skip_fgdc ? '' : 'and caching FGDC'}"

    # For URN style @see http://www.ietf.org/rfc/rfc2141.txt
    # For ARK @see https://wiki.ucop.edu/display/Curation/ARK
    prefix = case layer['Institution']
    when 'Stanford'
      'http://purl.stanford.edu/'
    when 'Tufts'
      'urn:geodata.tufts.edu:'
    when 'MassGIS'
      'urn:massgis.state.ma.us:'
    when 'Berkeley'
      'http://ark.cdlib.org/ark:/'
    when 'MIT'
      'urn:arrowsmith.mit.edu:'
    when 'Harvard'
      'urn:hul.harvard.edu:'
    else
      ''
    end
    uuid = prefix + URI.encode(id)
    
    # Parse out the Location to get the WMS/WFS/WCS URLs
    raise ArgumentError, "ERROR: #{id} no location" if layer['Location'].nil? or layer['Location'].empty?
    location = JSON::parse(layer['Location'])
    raise ArgumentError, "ERROR: #{id} has malformed location" unless location.is_a? Hash
    
    # Parse out the bounding box
    s = layer['MinY'].to_f
    w = layer['MinX'].to_f
    n = layer['MaxY'].to_f
    e = layer['MaxX'].to_f
    
    # Parse out the ContentDate date/time
    dt = DateTime.rfc3339(layer['ContentDate'])
    pub_dt = DateTime.rfc3339('2000-01-01T00:00:00Z') # XXX fake data, get from MODS
    
    access = layer['Access']
    collection = nil
    
    # Parse out the PURL and other metadata for Stanford
    if layer['Institution'] == 'Stanford'
      purl = location['purl']
      if purl.is_a? Array
        purl = purl.first
      end
      if purl.nil? and uuid =~ /^http/
        purl = uuid
      end
    else
      purl = nil
      # Because OGP does not deliminate keywords, we use a heuristic here
      %w{PlaceKeywords ThemeKeywords}.each do |k|
        unless layer[k] =~ /[;,]/ or layer[k].split.size < 4
          layer[k] = layer[k].split.join(';')
        end
      end
    end
    
    slug = to_slug(id, layer)
    
    layer_geom_type = layer['DataType'].to_s.downcase
    layer_geom_type = 'raster' if layer_geom_type == 'paper map'
    
    # @see https://github.com/OSGeo/Cat-Interop
    %w{wcs wfs wms}.each do |k|
      location[k] = location[k].first if location[k].is_a? Array
    end
    refs = {}
    refs['http://www.opengis.net/def/serviceType/ogc/wcs'] = "#{location['wcs']}" if location['wcs']
    refs['http://www.opengis.net/def/serviceType/ogc/wfs'] = "#{location['wfs']}" if location['wfs']
    refs['http://www.opengis.net/def/serviceType/ogc/wms'] = "#{location['wms']}" if location['wms']
    if purl
      refs["http://schema.org/thumbnailUrl"] = "http://stacks.stanford.edu/file/druid:#{id}/preview.jpg"
      refs["http://schema.org/url"] = "#{clean_uri(purl)}"
      refs["http://schema.org/DownloadAction"] = "http://stacks.stanford.edu/file/druid:#{id}/data.zip"
      refs["http://www.isotc211.org/schemas/2005/gmd/"] = "#{purl}.iso19139"
      refs["http://www.loc.gov/mods/v3"] = "#{purl}.mods"
    end
    
    # Make the conversion from OGP to GeoBlacklight
    #
    # @see http://dublincore.org/documents/dcmi-terms/
    # @see http://wiki.dublincore.org/index.php/User_Guide/Creating_Metadata
    # @see http://www.ietf.org/rfc/rfc5013.txt
    new_layer = {
      :uuid               => uuid,
      
      # Dublin Core elements
      :dc_creator_sm      => string2array(layer['Originator']),
      :dc_description_s   => layer['Abstract'],
      :dc_format_s        => (
        (layer_geom_type == 'raster') ? 
        'GeoTIFF' : # 'image/tiff' : 
        'Shapefile' # 'application/x-esri-shapefile'
      ), # XXX: fake data
      :dc_identifier_s    => uuid,
      :dc_language_s      => 'English', # 'en', # XXX: fake data
      :dc_publisher_s     => layer['Publisher'],
      :dc_rights_s        => access,
      :dc_subject_sm      => string2array(layer['ThemeKeywords']),
      :dc_title_s         => layer['LayerDisplayName'],
      :dc_type_s          => 'Dataset',  # or 'Image' for non-georectified, 
                                         # or 'PhysicalObject' for non-digitized maps
      # Dublin Core terms
      :dct_isPartOf_sm    => collection.nil?? nil : [collection],
      :dct_references_s   => refs.to_json.to_s,
      :dct_spatial_sm     => string2array(layer['PlaceKeywords']),
      :dct_temporal_sm    => [dt.year.to_s],
      :dct_issued_s       => pub_dt.year.to_s,
      :dct_provenance_s   => layer['Institution'],

     #
     # xmlns:georss="http://www.georss.org/georss"
     # A bounding box is a rectangular region, often used to define the extents of a map or a rough area of interest. A box contains two space seperate latitude-longitude pairs, with each pair separated by whitespace. The first pair is the lower corner, the second is the upper corner.
      :georss_box_s       => "#{s} #{w} #{n} #{e}",
      :georss_polygon_s   => "#{n} #{w} #{n} #{e} #{s} #{e} #{s} #{w} #{n} #{w}",
     
      # Layer-specific schema
      :layer_slug_s       => slug,
      :layer_id_s         => layer['WorkspaceName'] + ':' + layer['Name'],
      # :layer_srs_s        => 'EPSG:4326', # XXX: fake data
      :layer_geom_type_s  => layer_geom_type.capitalize,
      :layer_modified_dt  => Time.now.utc.strftime('%FT%TZ'),
      
      # derived fields used only by solr, for which copyField is insufficient
      :solr_bbox  => "#{w} #{s} #{e} #{n}", # minX minY maxX maxY
      :solr_ne_pt => "#{n},#{e}",
      :solr_sw_pt => "#{s},#{w}",
      :solr_geom  => "ENVELOPE(#{w}, #{e}, #{n}, #{s})",
      :solr_year_i => dt.year,
      :solr_issued_dt => pub_dt.strftime('%FT%TZ'), # Solr requires 1995-12-31T23:59:59Z
      :solr_wms_url => location['wms'],
      :solr_wfs_url => location['wfs'],
      :solr_wcs_url => location['wcs']
      
      # :layer_year_i       => dt.year#, # XXX: migrate to copyField
      # :ogp_area_f         => layer['Area'],
      # :ogp_center_x_f     => layer['CenterX'],
      # :ogp_center_y_f     => layer['CenterY'],
      # :ogp_georeferenced_b   => (layer['GeoReferenced'].to_s.downcase == 'true'),
      # :ogp_halfheight_f   => layer['HalfHeight'],
      # :ogp_halfwidth_f    => layer['HalfWidth'],
      # :ogp_layer_id_s     => layer['LayerId'],
      # :ogp_name_s         => layer['Name'],
      # :ogp_location_s     => layer['Location'],
      # :ogp_workspace_s    => layer['WorkspaceName']
    }
    
    # Remove any fields that are blank
    new_layer.each do |k, v| 
      new_layer.delete(k) if v.nil? or (v.respond_to?(:empty?) and v.empty?)
    end
    
    # Write the JSON record for the GeoBlacklight layer
    @output.write JSON::pretty_generate(new_layer)
    @output.write "\n,\n"
    
    unless skip_fgdc or layer['FgdcText'].nil? or layer['FgdcText'].empty?
      xml = Nokogiri::XML(layer['FgdcText'])
      xml.write_xml_to(File.open('data/fgdc/' + slug + '.xml', 'wb'), :encoding => 'UTF-8', :indent => 2)
    end
  end

  def close
    @output.write "\n {} \n]\n"
    @output.close
  end
    
  # @param [String] s has semi-colon/comma/gt delimited array
  # @return [Array] results as array
  def string2array(s)
    if s.to_s =~ /[;,>]/
      s.split(/\s*[;,>]\s*/).uniq.collect {|i| i.strip}
    elsif s.is_a?(String) and s.size > 0
      [s.strip]
    else
      nil
    end
  end
  
  @@slugs = {}
  def to_slug(id, layer)
    # strip out schema and usernames
    name = layer['Name'].sub('SDE_DATA.', '').sub('SDE.', '').sub('SDE2.', '').sub('GISPORTAL.GISOWNER01.', '').sub('GISDATA.', '').sub('MORIS.', '')
    unless name.size > 1 
      # use first word of title is empty name
      name = layer['LayerDisplayName'].split.first 
    end
    slug = layer['Institution'] + '-' + name
    
    # slugs should only have a-z, A-Z, 0-9, and -
    slug.gsub!(/[^a-zA-Z0-9\-]/, '-')
    slug.gsub!(/[\-]+/, '-')
    
    # only lowercase
    slug.downcase!
    
    # ensure slugs are unique for this pass
    if @@slugs.include?(slug)
      slug += '-' + sprintf("%06d", Random.rand(999999))
    end
    @@slugs[slug] = true

    slug
  end

  # Ensure that the WMS/WFS/WCS location values are as expected
  def validate_location(id, location)
    begin
      x = JSON::parse(location)
      if x['wms'].nil? or (x['wcs'].nil? and x['wfs'].nil?)
        raise ArgumentError, "ERROR: #{id}: Missing WMS or WCS/WFS: #{x}"
      end
      
      %w{wms wcs wfs}.each do |protocol|
        begin
          unless x[protocol].nil?
            if x[protocol].is_a? String
              x[protocol] = [x[protocol]]
            end
            
            unless x[protocol].is_a? Array
              raise ArgumentError, "ERROR: #{id}: Unknown #{protocol} value: #{x}"
            end
            
            x[protocol].each do |url|
              uri = clean_uri.parse(url)
              raise ArgumentError, "ERROR: #{id}: Invalid URL: #{uri}" unless uri.kind_of?(clean_uri::HTTP) or uri.kind_of?(clean_uri::HTTPS)
            end
          end
        rescue Exception => e
          raise ArgumentError, "ERROR: #{id}: Invalid #{k}: #{x}"
        end        
      end
      
      return x.to_json
    rescue JSON::ParserError => e
      raise ArgumentError, "ERROR: #{id}: Invalid JSON: #{location}"
    end
    nil
  end
  
  def lon? lon
    lon >= -180 and lon <= 180
  end
  
  def lat? lat
    lat >= -90 and lat <= 90
  end
end


# __MAIN__
#
SKIP_FGDC = false
TransformOgp.new(ARGV[0].nil?? 'data/transformed.json' : ARGV[0]) do |ogp|
  stats = { :accepted => 0, :rejected => 0 }
  Dir.glob('data/valid*.json') do |fn|
    s = ogp.transform_file(fn, SKIP_FGDC)
    stats[:accepted] += s[:accepted]
    stats[:rejected] += s[:rejected]
  end
  ap({:statistics => stats})
end

# example input data
__END__
[
{
  "Abstract": "The boundaries of each supervisorial district in Sonoma County based on 2000 census. Redrawn in 2001 using Autobound.",
  "Access": "Public",
  "Area": 0.9463444815860053,
  "Availability": "Online",
  "CenterX": -122.942159,
  "CenterY": 38.4580755,
  "ContentDate": "2000-01-01T01:01:01Z",
  "DataType": "Polygon",
  "FgdcText": "...",
  "GeoReferenced": true,
  "HalfHeight": 0.39885650000000084,
  "HalfWidth": 0.593161000000002,
  "Institution": "Berkeley",
  "LayerDisplayName": "SCGISDB2_BASE_ADM_SUPERVISOR",
  "LayerId": "28722/bk0012h5s52",
  "Location": "{\"wms\":[\"http://gis.lib.berkeley.edu:8080/geoserver/wms\"],\"tilecache\":[\"http://gis.lib.berkeley.edu:8080/geoserver/gwc/service/wms\"],\"download\":\"\",\"wfs\":[\"http://gis.lib.berkeley.edu:8080/geoserver/wfs\"]}",
  "MaxX": -122.348998,
  "MaxY": 38.856932,
  "MinX": -123.53532,
  "MinY": 38.059219,
  "Name": "ADM_SUPERVISOR",
  "PlaceKeywords": "Sonoma County County of Sonoma Sonoma California Bay Area",
  "Publisher": "UC Berkeley Libraries",
  "ThemeKeywords": "Supervisorial districts 1st District 2nd District 3rd District 4th District 5th District",
  "WorkspaceName": "UCB"
}
]
