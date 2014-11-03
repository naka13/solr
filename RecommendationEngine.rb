require 'rubygems'
require 'rsolr'
require 'json'
require 'cgi'

class RecommendationEngine
	if Rails.env == "production"
		SOLR_HOST = ENV['SOLR_HOST'] || 're02.voylla.com'
	elsif Rails.env == "staging"
		SOLR_HOST = ENV['SOLR_HOST'] || 're03.voylla.com'
	elsif Rails.env == "development"
		SOLR_HOST = ENV['SOLR_HOST'] || 'localhost'
	end
	SOLR_PORT = ENV['SOLR_PORT'] || '8983'
	SOLR_COLLECTION = ENV['SOLR_COLLECTION'] || 'voylla'

	VOYLLA_DOCID_FIELD = 'id'
	VOYLLA_PRODUCTID_FIELD = 'productId'
	VOYLLA_TAXONOMY_FIELD_NAME = 'productTaxonomyName'

	VOYLLA_DEFAULT_FILTER = ['-productTaxonomyName:Apparel',
				 '-productTaxonomyName:Dresses',
				 '-productTaxonomyName:"Shrugs, Jackets & Coats"',
				 '-productTaxonomyName:"Kurtis & Tunics"',
				 '-productTaxonomyName:"Salwar Suits"',
				 '-productTaxonomyName:"Scarves & Stoles"',
				 '-productTaxonomyName:Skirts',
				 '-productTaxonomyName:"Hair Accessories"',
				 '-productTaxonomyName:Shawls',
				 '+productTaxonomyName:[* TO *]',
				 '+productAvailableDateTs:[* TO NOW/DAY]',
				 '+pStock:[1 TO *]']

	VOYLLA_DEFAULT_FIELDS = 'id, productId, productName, productPermalink, productBrandSku, productIsReOrderable, productDesignerId, productDesignerId, productDesignerName, productTaxonomyName, productTaxonomyPermalink, productColors, productTagNames, productTagValues, productTags, productPromoNames, productPromoValues, productPromos, productAssetDetailsJson, pStock, mPrice, sPrice, productRelevance, variantId, variantSku, variantIsMaster, variantOption, variantOptionText, variantOptionJson, vStock, cPrice, Price, score, productAvailableDateTs'

	VOYLLA_FIELD_MAP = {'productTaxonomyName' => 'taxons', 'mPrice' => 'mrp', 'productPermalink' => 'permalink', 'productName' => 'name', 'productBrandSku' => 'brand_sku', 'productIsReOrderable' => 'is_re_orderable'}

	VOYLLA_DEFAULT_SORT_ORDER = 'score desc'

	VOYLLA_DEFAULT_ROWS = 30

	VOYLLA_DEFAULT_MLT_FIELDS = 'product_taxonomy_name,product_type_value,productDescription,productName,product_designer_name,product_property_color_new'
	VOYLLA_DEFAULT_MLT_QF = "product_taxonomy_name^2 product_type_value^2 productDescription^1 productName^1 product_property_color_new^1 product_surface_finish_value^1 product_theme_value^1 product_design_value^1"
	VOYLLA_DEFAULT_MLT_PF = "product_taxonomy_name^2 product_type_value^2 productDescription^1 productName^1 product_property_color_new^1 product_surface_finish_value^1 product_theme_value^1 product_design_value^1"
	VOYLLA_DEFAULT_MLT_QUERY_PARAMS = {:defType => 'edismax', :qf => VOYLLA_DEFAULT_MLT_QF, :pf => VOYLLA_DEFAULT_MLT_PF}
	VOYLLA_DEFAULT_MLT_RESULTS_COUNT = 24

	VOYLLA_EDISMAX_QF = 'vSku^1000 productTaxonomyName^100 productDesignerName^10 productName^10 productDescription^5 productTagNames^1 productTagValues^1 variantOption^5 productColors^1 productPromoValues^1'

	VOYLLA_EDISMAX_PF = 'productTaxonomyName^100 productDesignerName^10 productName^10 productDescription^5 productTagNames^1 productTagValues^1 variantOption^5 productColors^1 productPromoValues^1'

	VOYLLA_DEFAULT_QUERY_PARAMS = {:defType => 'edismax', :qf => VOYLLA_EDISMAX_QF, :pf => VOYLLA_EDISMAX_PF}

	VOYLLA_DEFAULT_FACET_FIELDS = ["{!ex=typetag}product_type_value","{!ex=occ}product_occasion_value","{!ex=coll}product_collection_value","{!ex=mat}product_material_value","{!ex=plat}product_plating_value","{!ex=stone}product_gemstones_value","{!ex=disc}product_discount_bucket","{!ex=pbucket}product_selling_price","{!ex=txmny,taxon}product_parent_taxonomy_name","{!ex=taxon}product_taxonomy_name","variant_option_type_value"]
	VOYLLA_DEFAULT_FACET_FIELDS_SHOP = ["{!ex=typetag}product_type_value","{!ex=occ}product_occasion_value","{!ex=coll}product_collection_value","{!ex=mat}product_material_value","{!ex=plat}product_plating_value","{!ex=stone}product_gemstones_value","{!ex=disc}product_discount_bucket","{!ex=pbucket}product_selling_price","{!ex=txmny,taxon,typetag}product_parent_taxonomy_name","{!ex=taxon,typetag}product_taxonomy_name","variant_option_type_value"]

	VOYLLA_DEFAULT_STATS_FIELDS = "product_selling_price"

	def initialize()
		@solrUri = 'http://' + SOLR_HOST + ':' + SOLR_PORT + '/solr/' + SOLR_COLLECTION + '/'
	end

	def connect()
		# Direct connection
		@rSolrObj = RSolr.connect :url => @solrUri, :read_timeout => 10, :open_timeout => 10, :retry_503 => 1, :retry_after_limit => 1
	end

	private
	def querySolr(op, queryParams)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# send a request to solr /select
		if op == "mlt"
			solrReply = @rSolrObj.get op, :params => VOYLLA_DEFAULT_MLT_QUERY_PARAMS.merge(queryParams)
		else
			solrReply = @rSolrObj.get op, :params => VOYLLA_DEFAULT_QUERY_PARAMS.merge(queryParams)
		end

		responseHeader = solrReply['responseHeader']
		if ( responseHeader['status'] == 0 )
			docs = solrReply['response'] if solrReply.has_key?('response')
			docs = solrReply['grouped'] if solrReply.has_key?('grouped')	
		end

		rescue RSolr::Error => sE
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, docs, responseHeader
	end

	private
        def facetedStatsQuerySolr(op, queryParams)														####return facet counts and stats for specified fields
                begin
                error = { 'code' => 0, 'msg' => '' }

                solrReply = @rSolrObj.get op, :params => VOYLLA_DEFAULT_QUERY_PARAMS.merge(queryParams)					####queryparams must include faect, facet.fields, stats and stats.field

                responseHeader = solrReply['responseHeader']
                facetCounts = solrReply['facet_counts']																	####hash giving facet counts for specified field(s)
                stats = solrReply["stats"]																				####hash giving stats for specified field(s)
                if ( responseHeader['status'] == 0 )
                        docs = solrReply['response'] if solrReply.has_key?('response')
                        docs = solrReply['grouped'] if solrReply.has_key?('grouped')
                end

                rescue RSolr::Error => sE
                        error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

                rescue => e
                        puts e.inspect
                        error = { 'code' => -1, 'msg' => e.message }
                end

                return error, docs, responseHeader, facetCounts, stats
        end

    private
	def generateFilterQuery(q,c)
		@q = q

		@types = @q["type"]
		@occs = @q["occasion"]
		@colls = @q["collection"]
		@mats = @q["material"]
		@plats = @q["plating"]
		@stones = @q["stone"]
		@price = @q["vprice_between"]
		@colors = @q["color"]
		@size = @q["has_size"]
		@discount = @q["discount"]
		@price_buckets = @q["price_bucket"]
		@taxonomy = @q["taxonomy1"]
		@taxon = @q["taxon1"]

		####Initialize filter query for each on the filter options
		@fqtype = ""
		@fqocc = ""
		@fqcoll = ""
		@fqmat = ""
		@fqplat = ""
		@fqstone = ""
		@fqprice = ""
		@fqsize = ""
		@fqcolor = ""
		@fqdiscount = ""
		@fqprice_bucket = ""
		@fqtaxonomy = ""
		@fqtaxon = ""

		####prepare a filter query for each filter (occasion, type, material etc.)
		if !@types.nil?
			@qtype = '("' + @types.join('"OR"').chomp("?") + '")'
			@fqtype = "{!tag=typetag}product_type_value:" + @qtype
		end

		if !@occs.nil?
			@qocc = '("' + @occs.join('" OR "').chomp("?") + '")'					####join each element of the array by OR
			@fqocc = "{!tag=occ}product_occasion_value:" + @qocc								####corresponding solr filter query on the solr field
		end

		if !@colls.nil?
			@qcoll = '("' + @colls.join('" OR "').chomp("?") + '")'
			@fqcoll = "{!tag=coll}product_collection_value:" + @qcoll
		end

		if !@mats.nil?
			@qmat = '("' + @mats.join('" OR "').chomp("?") + '")'
			@fqmat = "{!tag=mat}product_material_value:" + @qmat
		end

		if !@plats.nil?
			@qplat = '("' + @plats.join('" OR "').chomp("?") + '")'
			@fqplat = "{!tag=plat}product_plating_value:" + @qplat
		end

		if !@stones.nil?
			@qstone = '("' + @stones.join('" OR "').chomp("?") + '")'
			@fqstone = "{!tag=stone}product_gemstones_value:" + @qstone
		end

		if !@price.nil?
			if c == "INR"
				@fqprice = "product_selling_price:[" + @price[0].chomp('"').chomp("?").upcase + "]"
			elsif c == "USD"
				@price = @price.map{|x| [(x.split(" ")[0].to_i-1>=0 ? x.split(" ")[0].to_i-1  : 0).to_s,x.split(" ")[1],x.split(" ")[2]].join(" ")}
				conversion = CurrencyConversionFactor.where(:currency => "USD").last.value
				@qprice = @price[0].chomp('"').chomp("?").upcase.split(" ").map {|x| Integer(x)/conversion rescue x }.join(" ")
				@fqprice = "product_selling_price:"+ "[" + @qprice + "]"
			end				
		end

		if !@size.nil?
			@qsize = "(" + @size.join(" OR ").chomp("?") + ")"
			@fqsize = "variant_option_type_value:" + @qsize
		end

		if !@colors.nil?
			@colors = @colors.map { |color| "*#{color.chomp("?")}*" }
			@qcolor = "(" + @colors.join(" OR ").chomp("?") + ")"
			@fqcolor1 = "product_property_color:"+@qcolor
			@fqcolor2 = "product_property_color_new:"+@qcolor
			@fqcolor = @fqcolor1 + " OR " + @fqcolor2
		end

		if !@discount.nil?
			@qdiscount = @discount.min.chomp("?")
			@fqdiscount = "{!tag=disc}product_discount_bucket:[" + @qdiscount + " TO *]"
		end

		if !@price_buckets.nil?
			if c == "INR"
				@buckets = @price_buckets.map {|bucket| "[#{bucket.chomp("?")}]"}
				@qbucket = "(" + @buckets.join(" OR ").chomp("?") + ")"
			elsif c == "USD"
				@buckets = @price_buckets.map{|x| [(x.split(" ")[0].to_i-1>=0 ? x.split(" ")[0].to_i-1  : 0).to_s,x.split(" ")[1],x.split(" ")[2]].join(" ")}
				conversion = CurrencyConversionFactor.where(:currency => "USD").last.value
				@buckets = @buckets.map {|x| x.chomp("?").split(" ")}.map{|y| y.map{ |z| Integer(z)/conversion rescue z }.join(" ")}
				@buckets = @buckets.map {|bucket| "[#{bucket}]"}
				@qbucket = "(" + @buckets.join(" OR ").chomp("?") + ")"
			end					
			@fqprice_bucket = "{!tag=pbucket}product_selling_price:" + @qbucket
		end

		@fqprice = [@fqprice_bucket, @fqprice].select{|c| !c.empty?}.join(" OR ")

		if !@taxonomy.nil?
			@fqtaxonomy = "{!tag=txmny}product_parent_taxonomy_name:" + '"' + @taxonomy.chomp("?") + '"'
		end

		if !@taxon.nil?
			@fqtaxon = "{!tag=taxon}product_taxonomy_name:" + '"' + @taxon.chomp("?") + '"'
		end

		@fq = [VOYLLA_DEFAULT_FILTER, @fqtype, @fqocc, @fqcoll, @fqmat, @fqplat, @fqstone, @fqprice, @fqsize, @fqcolor, @fqdiscount, @fqtaxonomy, @fqtaxon].reject!{|c| c.empty?}			####Join each filter query
		puts q,@fq

		return @fq

	end

	private
	def queryFilterTagDocs(q, t, c, start = 0, rows = 10000, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		@qtaxonomy = t.gsub(/[+-]/," ").split.map(&:capitalize).join(" ").gsub("And","&")

		#### fetch query data from params
		@q = q

		@taxon = @q["taxon"]
		if !@taxon.nil?
			@qtaxon = @taxon.gsub(/[+-]/," ").split.map(&:capitalize).join(" ").gsub("And","and")
		end

		@tag = @q["tag"]
		if !@tag.nil?
			@tag = @tag.gsub(/[+-]/," ").split.map(&:capitalize).join(" ")
		end

		@fq = generateFilterQuery(q,c)

		puts q,@fq

		####defining facet fileds and stast field
		facet_fields = VOYLLA_DEFAULT_FACET_FIELDS
		stats_field = VOYLLA_DEFAULT_STATS_FIELDS

		price_ranges = ProductFilters.price_bucket_filters(c)

		if c == "INR"
			facet_range_field = "{!ex=pbucket}product_selling_price"
			facet_range_include = ["lower","outer"]
		else
			facet_range_field = '{!ex=pbucket}product_selling_price_in_dollars'
			facet_range_include = ["upper","lower","outer"]
		end
		facet_gap = price_ranges[:gap]
		facet_end = price_ranges[:end]

		# prepare query to be sent to solr
		if @tag.nil?						####if it is a taxon page (/jewellery/earrings)
			if !@qtaxon.nil?
				@main_query = "{!tag=taxon}product_taxonomy_name:" + '"' + @qtaxon + '"'
				@filter_query = @fq.push("-product_type_value:"+'"Precious"')
			else
				@main_query = "{!tag=txmny,taxon}product_parent_taxonomy_name:" + '"' + @qtaxonomy + '"'
				@filter_query = @fq.push("-product_type_value:"+'"Precious"')
 			end
		else 								####if it is a sub-category page (/jewellery/earrings/jhumkis)
				@main_query = "{!tag=typetag}product_type_value:"+ '"' + @tag + '"'
				@fqtaxon = "{!tag=taxon}product_taxonomy_name:"+ '"' + @qtaxon + '"'
				if @tag == "Precious"
					@filter_query = @fq.push(@fqtaxon)
				else
					@filter_query = @fq.push(@fqtaxon).push("-product_type_value:"+'"Precious"')
				end
		end
		queryParams = {:q => @main_query, :fq => @filter_query, :rows => rows, :fl => fields, :sort => sortOrder, :facet => true, "facet.field" => facet_fields, :stats => true, "stats.field" => stats_field, "facet.range" => facet_range_field, "facet.range.start" => 0, "facet.range.end" => facet_end, "facet.range.gap" => facet_gap, "facet.range.other" => "after", "facet.range.include" => facet_range_include}

		# send query to Solr
		(error, response, responseHeader, facetCounts, stats) = facetedStatsQuerySolr('select', queryParams)

		if !facetCounts.nil?
			facet_counts = parseFacets(facetCounts,c)
		else
			facet_counts = {"product_collection_value" => {}, "product_material_value" => {}, "product_plating_value" => {}, "product_gemstones_value" => {}, "product_type_value" => {}, "product_occasion_value" => {}, "product_discount_bucket" => {}, "product_parent_taxonomy_name" => {}, "product_selling_price" => {}, "product_taxonomy_name" => {}}
		end

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader, facet_counts, stats
	end

	private
	def queryFilterDocs(q, c, start = 0, rows = 10000, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		@main_query = q["q"]

		@filter_query = generateFilterQuery(q,c)

		facet_fields = VOYLLA_DEFAULT_FACET_FIELDS
		stats_field = VOYLLA_DEFAULT_STATS_FIELDS

		price_ranges = ProductFilters.price_bucket_filters(c)

		if c == "INR"
			facet_range_field = "{!ex=pbucket}product_selling_price"
			facet_range_include = ["lower","outer"]
		else
			facet_range_field = '{!ex=pbucket}product_selling_price_in_dollars'
			facet_range_include = ["upper","lower","outer"]
		end
		facet_gap = price_ranges[:gap]
		facet_end = price_ranges[:end]
		
		# prepare query for solr
		queryParams = {:q => @main_query, :fq => @filter_query, :rows => rows, :fl => fields, :sort => sortOrder, :facet => true, "facet.field" => facet_fields, :stats => true, "stats.field" => stats_field, "facet.range" => facet_range_field, "facet.range.start" => 0, "facet.range.end" => facet_end, "facet.range.gap" => facet_gap, "facet.range.other" => "after", "facet.range.include" => facet_range_include}

		# send query to Solr
		(error, response, responseHeader, facetCounts, stats) = facetedStatsQuerySolr('select', queryParams)

		if !facetCounts.nil?
			facet_counts = parseFacets(facetCounts,c)
		else
			facet_counts = {"product_collection_value" => {}, "product_material_value" => {}, "product_plating_value" => {}, "product_gemstones_value" => {}, "product_type_value" => {}, "product_occasion_value" => {}, "product_discount_bucket" => {}, "product_parent_taxonomy_name" => {}, "product_selling_price" => {}, "product_taxonomy_name" => {}}
		end

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader, facet_counts, stats
	end

	private
	def queryRelatedProducts(taxon, type, price, rows, start = 0, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# clean query
		#taxon = queryCleaner1(taxon)
		type = queryCleaner1(type)
		price1 = price * 1.5
		price2 = price * 2.5
		# prepare query
		queryParams = {:q => "productTagValues:"+type, :fq => "+productAvailableDateTs:[* TO NOW/DAY], +pStock:[1 TO *], +product_taxonomy_name:"+'"'+taxon+'", '+"+Price:[#{price1} TO #{price2}]", :start => start, :rows => rows, :fl => fields, :sort => sortOrder}
		puts queryParams

		# send query to Solr
		(error, response, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		if numDocs < 24
			error1, numDocs1, docs1, responseHeader1 = queryRelaxedRelatedProducts(taxon, type, price, rows)	
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		if !docs.nil?
			if !docs1.nil?
				docs1.each { |doc|
					if !docs.include? doc
						docs << doc
					end
				}
			end
		else
			docs = docs1
		end

		return error, numDocs, docs, responseHeader			
	end

	private
	def queryRelaxedRelatedProducts(taxon, type, price, rows, start = 0, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = "product_selling_price desc")
		begin
		error = { 'code' => 0, 'msg' => '' }

		# clean query
		#taxon = queryCleaner1(taxon)
		type = queryCleaner1(type)

		# prepare query
		queryParams = {:q => "productTagValues:"+type, :fq => "+productAvailableDateTs:[* TO NOW/DAY], +pStock:[1 TO *], +product_taxonomy_name:"+'"'+taxon+'"', :start => start, :rows => rows, :fl => fields, :sort => sortOrder}
		puts queryParams

		# send query to Solr
		(error, response, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader			
	end

	private
	def queryRecommendedProducts(taxon, collection, type, rows, start = 0, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		##generate filter query
		if taxon == "Anklets" and collection == "Traditional and Imitation"
			@fq = '((product_taxonomy_name:Mangalsutras) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:Traditional and Imitation) AND (product_type_value:"With Gemstone")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:Traditional and Imitation) AND (product_type_value:"Jhumkis")) OR ((product_taxonomy_name:"Necklace Sets") AND  (productTagValues:Traditional and Imitation) AND (product_type_value:"Maang Tika Set")))'
		elsif taxon == "Anklets" and collection == "Chunky"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:Chunky) AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:Chunky) AND (product_type_value:"With chain")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:Chunky) AND (product_type_value:"Beaded")))'
		elsif taxon == "Anklets" and collection == "Modern"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:Modern) AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:Modern) AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:Modern) AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:Modern) AND (product_type_value:"Danglers")))'
		elsif taxon == "Anklets" and collection == "Coloured Gems"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:coloured gems) AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:coloured gems) AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:coloured gems) AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:coloured gems) AND (product_type_value:"Bangles")))'
		elsif taxon == "Mangalsutras"
			@fq = '(((product_taxonomy_name:"Toe Rings") AND (productTagValues:traditional and imitation) AND (product_type_value:"With Gemstone")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:traditional and imitation)) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:traditional and imitation) AND (product_type_value:"Thewa")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:traditional and imitation) AND (product_type_value:"Choker")))'
		elsif taxon =="Toe Rings" and collection == "Traditional and Imitation" and type == "With Gemstone"
			@fq = '(((product_taxonomy_name:"Mangalsutras")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Traditional and imitation") AND (product_type_value:"Thewa")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker") OR (product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")))'
		elsif taxon=="Toe Rings" and collection == "Traditional and Imitation" and type == "Without Gemstone"
			@fq = '(((product_taxonomy_name:"Mangalsutras")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Traditional and imitation") AND (product_type_value:"Thewa")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")))'
		elsif taxon=="Toe Rings" and type == "Oxidized"
    		@fq = '(((product_taxonomy_name:"Mangalsutras")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")))'
		elsif taxon=="Toe Rings" and collection == "Chunky"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Cuff")))'
		elsif taxon=="Toe Rings" and collection == "Modern"
			@fq = '(((product_taxonomy_name:"Mangalsutras")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chain")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Single Stone")) OR ((product_taxonomy_name:"Pendents") AND (productTagValues:"Modern") AND (product_type_value:"Without Chain")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")))'
		elsif taxon == "Toe Rings" and collection == "Coloured Gems"
			@fq = '(((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Choker")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Mangalsutras")))'
		elsif taxon == "Earrings" and collection == "Traditional and Imitation" and type == "Jhumkis"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Traditional and Imitation")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")))'
		elsif taxon == "Earrings" and collection == "Traditional and Imitation" and type == "Danglers"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Traditional and Imitation")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Jhumkis")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")))'
		elsif taxon == "Earrings" and collection == "Traditional and Imitation" and type == "Studs"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Link")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Single Stone")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")))'
		elsif taxon == "Earrings" and collection == "Traditional and Imitation" and type == "Drops"
    		@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Single Stone")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")))'
		elsif taxon == "Earrings" and collection == "Traditional and Imitation" and type == "Hoops"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Traditional and Imitation")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")))'
		elsif taxon == "Earrings" and collection == "Modern" and type == "Jhumkis"
    		@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")))'
		elsif taxon == "Earrings" and collection == "Modern" and type == "Danglers"
    		@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")))'
		elsif taxon == "Earrings" and collection == "Modern" and type == "Studs"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"Without chain")))'
		elsif taxon == "Earrings" and collection == "Modern" and type == "Drops"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Link")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"Without chain")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Modern") AND (product_type_value:"Links")))'
		elsif taxon == "Earrings" and collection == "Modern" and type == "Hoops"
    		@fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Modern") AND (product_type_value:"Links")))'
    	elsif taxon == "Earrings" and collection == "Chunky" and type == "Jhumkis"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beads")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")))'
		elsif taxon == "Earrings" and collection == "Chunky" and type == "Danglers"
		   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Wallets") AND (product_type_value:"Double Fold")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")))'
		elsif taxon == "Earrings" and collection == "Chunky" and type == "Studs"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Pendant")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"beaded")) OR ((product_taxonomy_name:"Wallets") AND (product_type_value:"Double Fold")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beads")))'
		elsif taxon == "Earrings" and collection == "Chunky" and type == "Drops"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Studs")))'
		elsif taxon == "Earrings" and collection == "Chunky" and type == "Hoops"
			@fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Studs")))'
		elsif taxon == "Earrings" and collection == "Coloured Gems" and type == "Jhumkis"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Link")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured gems") AND (product_type_value:"Beaded")))'
		elsif taxon == "Earrings" and collection == "Coloured Gems" and type == "Danglers"
			@fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured gems") AND (product_type_value:"Beaded")))'

elsif taxon == "Earrings" and collection == "Coloured Gems" and type == "Studs"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured gems") AND (product_type_value:"Cocktail")))'

elsif taxon == "Earrings" and collection == "Coloured Gems" and type == "Drops"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured gems") AND (product_type_value:"Cocktail")))'

elsif taxon == "Earrings" and collection == "Coloured Gems" and type == "Hoops"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Link")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured gems") AND (product_type_value:"Beaded")))'

elsif taxon == "Necklace Sets" and collection == "Traditional and Imitation" and type == "Thewa"
   @fq = '(((product_taxonomy_name:"Bags") AND (productTagValues:"Clutches") AND (product_type_value:"Traditional and Imitation")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")))'

elsif taxon == "Necklace Sets" and collection == "Traditional and Imitation" and type == "Choker"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")))'

elsif taxon == "Necklace Sets" and collection == "Traditional and Imitation" and type == "Pearl"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")))'

elsif taxon == "Necklace Sets" and collection == "Traditional and Imitation" and type == "Kundan"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")))'

elsif taxon == "Necklace Sets" and collection == "Traditional and Imitation" and type == "Maang Tika Set"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")))'

elsif taxon == "Necklace Sets" and collection == "Chunky" and type == "Fashion"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Wallets") AND (product_type_value:"Single Fold")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")))'

elsif taxon == "Necklace Sets" and collection == "Modern" and type == "Choker"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")))'

elsif taxon == "Necklace Sets" and collection == "Modern" and type == "Pearl"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Single Stone")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Necklace Sets" and collection == "Modern" and type == "Kundan"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Single Stone")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Necklace Sets" and collection == "Modern" and type == "Maang Tika Set"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Single Stone")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Necklace Sets" and collection == "Coloured Gems" and type == "Choker"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")))'

elsif taxon == "Necklace Sets" and collection == "Coloured Gems" and type == "Pearl"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")))'

elsif taxon == "Necklace Sets" and collection == "Coloured Gems" and type == "Kundan"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")))'

elsif taxon == "Necklace Sets" and collection == "Coloured Gems" and type == "Maang Tika Set"
   @fq = '(((product_taxonomy_name:"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")))'

elsif taxon == "Pendant Sets" and collection == "Traditional and Imitation" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cluster")) OR ((product_taxonomy_name"Pouches") AND (product_type_value:"Potli")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Pendant Sets" and collection == "Traditional and Imitation" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cluster")) OR ((product_taxonomy_name"Pouches") AND (product_type_value:"Potli")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Pendant Sets" and collection == "Chunky" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beads")))'

elsif taxon == "Pendant Sets" and collection == "Chunky" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beads")))'

elsif taxon == "Pendant Sets" and collection == "Modern" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Band")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Pendant Sets" and collection == "Modern" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Band")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Pendant Sets" and collection == "Coloured Gems" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Pendant Sets" and collection == "Coloured Gems" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Rings" and collection == "Traditional and Imitation" and type == "Cocktail"
   @fq = '(((product_taxonomy_name:"Clutches") AND (productTagValues:"Traditional and Imitation")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Maang Tika Set")))'

elsif taxon == "Rings" and collection == "Traditional and Imitation" and type == "Bands"
   @fq = '(((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstones")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Studs")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")))'

elsif taxon == "Rings" and collection == "Traditional and Imitation" and type == "Single Stone"
   @fq = '(((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Drops")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kundan")))'

elsif taxon == "Rings" and collection == "Traditional and Imitation" and type == "Clusters"
   @fq = '(((product_taxonomy_name:"Pouches") AND (product_type_value:"Potli")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Jhumkis")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kundan")))'

elsif taxon == "Rings" and collection == "Chunky" and type == "Fashion"
   @fq = '(((product_taxonomy_name:"Pouches") AND (product_type_value:"Pouch")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Hoops")))'

elsif taxon == "Rings" and collection == "Modern" and type == "Cocktail"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Links")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"Without Chain")))'

elsif taxon == "Rings" and collection == "Modern" and type == "Bands"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Links")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"Without Chain")))'

elsif taxon == "Rings" and collection == "Modern" and type == "Single Stone"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Hoops")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Modern") AND (product_type_value:"Without Chain")))'

elsif taxon == "Rings" and collection == "Modern" and type == "Clusters"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Hoops")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Modern") AND (product_type_value:"Without Chain")))'

elsif taxon == "Rings" and collection == "Coloured Gems" and type == "Cocktail"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Rings" and collection == "Coloured Gems" and type == "Bands"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Rings" and collection == "Coloured Gems" and type == "Single Stone"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Studs")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Rings" and collection == "Coloured Gems" and type == "Clusters"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Bracelets" and collection == "Traditional and Imitation" and type == "Beaded"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cluster")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Without Chain")))'

elsif taxon == "Bracelets" and collection == "Traditional and Imitation" and type == "Link"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Jhumkis")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Single Stone")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Chain")))'

elsif taxon == "Bracelets" and collection == "Traditional and Imitation" and type == "Cuff"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Jhumkis")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Traditional and Imitation")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Chain")))'

elsif taxon == "Bracelets" and collection == "Traditional and Imitation" and type == "Kada"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Maang Tika Set")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Traditional and Imitation")))'

elsif taxon == "Bracelets" and collection == "Traditional and Imitation" and type == "Bangles"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Maang Tika Set")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Traditional and Imitation")))'

elsif taxon == "Bracelets" and collection == "Chunky" and type == "Beaded"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Pouch")))'

elsif taxon == "Bracelets" and collection == "Chunky" and type == "Link"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Handbags") AND (product_type_value:"Sling Bag")))'

elsif taxon == "Bracelets" and collection == "Chunky" and type == "Cuff"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Handbags") AND (product_type_value:"Sling Bag")))'

elsif taxon == "Bracelets" and collection == "Chunky" and type == "Kada"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Handbags") AND (product_type_value:"Tote Bag")))'

elsif taxon == "Bracelets" and collection == "Chunky" and type == "Bangles"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Handbags") AND (product_type_value:"Tote Bag")))'

elsif taxon == "Bracelets" and collection == "Modern" and type == "Beaded"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"with Chain")))'

elsif taxon == "Bracelets" and collection == "Modern" and type == "Link"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"with Chain")))'

elsif taxon == "Bracelets" and collection == "Modern" and type == "Cuff"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Hoops")) OR ((product_taxonomy_name"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"with Chain")))'

elsif taxon == "Bracelets" and collection == "Modern" and type == "Kada"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"with Chain")))'

elsif taxon == "Bracelets" and collection == "Modern" and type == "Bangles"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Modern") AND (product_type_value:"with Chain")))'

elsif taxon == "Bracelets" and collection == "Coloured Gems" and type == "Beaded"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Bracelets" and collection == "Coloured Gems" and type == "Link"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Bracelets" and collection == "Coloured Gems" and type == "Cuff"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Bracelets" and collection == "Coloured Gems" and type == "Kada"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Maang Tika Set")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Bracelets" and collection == "Coloured Gems" and type == "Bangles"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Choker")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Necklaces" and collection == "Traditional and Imitation" and type == "Bib"
   @fq = '(((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Hoops")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")))'

elsif taxon == "Necklaces" and collection == "Traditional and Imitation" and type == "Pendant"
   @fq = '(((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Drops")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Single Stone")))'

elsif taxon == "Necklaces" and collection == "Traditional and Imitation" and type == "Beaded"
   @fq = '(((product_taxonomy_name:"Anklets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Links")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Cocktail")))'

elsif taxon == "Necklaces" and collection == "Traditional and Imitation" and type == "Chains"
   @fq = '(((product_taxonomy_name:"Pendants") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Without Chain")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Drops")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Without Gemstone")))'

elsif taxon == "Necklaces" and collection == "Chunky" and type == "Bib"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Pendants") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Handbags") AND (product_type_value:"Sling Bag")))'

elsif taxon == "Necklaces" and collection == "Chunky" and type == "Pendant"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Handbags") AND (product_type_value:"Tote Bag")))'

elsif taxon == "Necklaces" and collection == "Chunky" and type == "Beaded"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"hoops")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Handbags") AND (product_type_value:"Pouch")))'

elsif taxon == "Necklaces" and collection == "Chunky" and type == "Chains"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Chunky") AND (product_type_value:"With Chain")) OR ((product_taxonomy_name:"Wallets") AND (product_type_value:"Double Fold")))'

elsif taxon == "Necklaces" and collection == "Modern" and type == "Bib"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Pendant Sets") AND (productTagValues:"Modern") AND (product_type_value:"Without Chain")))'

elsif taxon == "Necklaces" and collection == "Modern" and type == "Pendant"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Necklaces" and collection == "Modern" and type == "Chains"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Necklaces" and collection == "Coloured Gems" and type == "Bib"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Necklaces" and collection == "Coloured Gems" and type == "Pendant"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Studs")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Necklaces" and collection == "Coloured Gems" and type == "Beaded"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Necklaces" and collection == "Coloured Gems" and type == "Chains"
   @fq = '(((product_taxonomy_name:"Earrings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Cocktail")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Pendants" and collection == "Traditional and Imitation" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name"Pouches") AND (product_type_value:"Potli")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Pendants" and collection == "Traditional and Imitation" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name"Pouches") AND (product_type_value:"Potli")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Toe Rings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"With Gemstone")))'

elsif taxon == "Pendants" and collection == "Chunky" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beads")))'

elsif taxon == "Pendants" and collection == "Chunky" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunk"y") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Anklets") AND (productTagValues:"Chunky") AND (product_type_value:"Beads")))'

elsif taxon == "Pendants" and collection == "Modern" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Pendants" and collection == "Modern" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Bands")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Link")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Modern") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Pendants" and collection == "Coloured Gems" and type == "With Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Pendants" and collection == "Coloured Gems" and type == "Without Chain"
   @fq = '(((product_taxonomy_name:"Rings") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Clusters")) OR ((product_taxonomy_name"Bracelets") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Necklaces") AND (productTagValues:"Coloured Gems") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Clutches") AND (productTagValues:"Modern")))'

elsif taxon == "Clutches" and collection == "Traditional and Imitation"
   @fq = '(((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Thewa")))'

elsif taxon == "Clutches" and type == "Modern"
   @fq = '(((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Modern") AND (product_type_value:"Chains")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Modern") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Modern") AND (product_type_value:"Cuff")) OR ((product_taxonomy_name:"Rings") AND (productTagValues:"Modern") AND (product_type_value:"Cocktail")))'

elsif taxon == "Clutches" and type == "Traditional and Imitation"
   @fq = '(((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Thewa")))'

elsif taxon == "Handbag" and type == "Sling Bag"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Necklace Sets") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Bangles")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Pouch")))'

elsif taxon == "Handbag" and type == "Tote Bag"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Pouch")))'

elsif taxon == "Pouches" and type == "Pouch"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Fashion")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Wallets") AND (product_type_value:"Single Fold")))'

elsif taxon == "Pouches" and type == "Potli"
   @fq = '(((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Choker")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Kada")) OR ((product_taxonomy_name:"Necklace Sets") AND (productTagValues:"Traditional and Imitation") AND (product_type_value:"Thewa")))'

elsif taxon == "Wallets" and type == "Single Fold"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Pouch")))'

elsif taxon == "Wallets" and type == "Double Fold"
   @fq = '(((product_taxonomy_name:"Necklaces") AND (productTagValues:"Chunky") AND (product_type_value:"Bib")) OR ((product_taxonomy_name"Earrings") AND (productTagValues:"Chunky") AND (product_type_value:"Danglers")) OR ((product_taxonomy_name:"Bracelets") AND (productTagValues:"Chunky") AND (product_type_value:"Beaded")) OR ((product_taxonomy_name:"Pouches") AND (product_type_value:"Pouch")))'

		else
			puts "hello"
			return nil, nil, nil, nil,nil
		end

		# prepare query params
		group_field = "product_taxonomy_name_group"
		queryParams = {:q => "*:*", :fq => "+productAvailableDateTs:[* TO NOW/DAY], +pStock:[1 TO *], +"+@fq, :start => start, :fl => fields, :sort => sortOrder, :group => true, "group.field" => group_field, "group.limit" => 6}
		puts queryParams

		# send query to Solr
		(error, grouped, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && grouped.has_key?(group_field))
			numDocs = grouped[group_field]['matches']
			numGroups = grouped[group_field]['groups'].count
			groups = grouped[group_field]['groups']

			groups = parseResults(groups, true, true)
		else
			numGroups = 0
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numGroups = 0
			numDocs = 0
			puts sE.inspect
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numGroups = 0
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, numGroups, groups, responseHeader
	end

	private
	def queryFilterPromoDocs(q, c, start = 0, rows = 10000, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# fetch query data from params
		@q = q
		@promo = @q["promo"]
		
		@filter_query = generateFilterQuery(q,c)

		puts q,@filter_query

		facet_fields = VOYLLA_DEFAULT_FACET_FIELDS
		stats_field = VOYLLA_DEFAULT_STATS_FIELDS
		
		price_ranges = ProductFilters.price_bucket_filters(c)

		if c == "INR"
			facet_range_field = "{!ex=pbucket}product_selling_price"
			facet_range_include = ["lower","outer"]
		else
			facet_range_field = '{!ex=pbucket}product_selling_price_in_dollars'
			facet_range_include = ["upper","lower","outer"]
		end
		facet_gap = price_ranges[:gap]
		facet_end = price_ranges[:end]
		
		# prepare query
		if !@promo.nil?
			queryParams = {:q => "productPromoValues:"+@promo, :fq => @filter_query, :start => start, :rows => rows, :fl => fields, :sort => sortOrder, :facet => true, "facet.field" => facet_fields, :stats => true, "stats.field" => stats_field, "facet.range" => facet_range_field, "facet.range.start" => 0, "facet.range.end" => facet_end, "facet.range.gap" => facet_gap, "facet.range.other" => "after", "facet.range.include" => facet_range_include}
		else
			queryParams = {:q => "*:*", :fq => @filter_query, :start => start, :rows => rows, :fl => fields, :sort => sortOrder, :facet => true, "facet.field" => facet_fields, :stats => true, "stats.field" => stats_field, "facet.range" => facet_range_field, "facet.range.start" => 0, "facet.range.end" => facet_end, "facet.range.gap" => facet_gap, "facet.range.other" => "after", "facet.range.include" => facet_range_include}
		end

		# send query to Solr
		(error, response, responseHeader, facetCounts, stats) = facetedStatsQuerySolr('select', queryParams)

		if !facetCounts.nil?
			facet_counts = parseFacets(facetCounts,c)
		else
			facet_counts = {"product_collection_value" => {}, "product_material_value" => {}, "product_plating_value" => {}, "product_gemstones_value" => {}, "product_type_value" => {}, "product_occasion_value" => {}, "product_discount_bucket" => {}, "product_parent_taxonomy_name" => {}, "product_selling_price" => {}, "product_taxonomy_name" => {}}
		end

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader, facet_counts, stats
	end

	private
	def queryPromoDocs(q, start = 0, rows = 250, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# clean query
		q = queryCleaner1(q)
		puts q

		# prepare query
		queryParams = {:q => "productPromoValues:"+q, :fq => VOYLLA_DEFAULT_FILTER, :start => start, :rows => rows, :fl => fields, :sort => sortOrder}

		# send query to Solr
		(error, response, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader
	end

	def queryMore(op, queryParams)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# send a request to solr /select
		solrReply = @rSolrObj.get op, :params => VOYLLA_DEFAULT_QUERY_PARAMS.merge(queryParams)

		responseHeader = solrReply['responseHeader']
		if ( responseHeader['status'] == 0 )
			docs = solrReply['response'] if solrReply.has_key?('response')
			docs = solrReply['grouped'] if solrReply.has_key?('grouped')	
		end

		rescue RSolr::Error => sE
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, docs, responseHeader
	end

        private
        def facetedQuerySolr(op, queryParams)
                begin
                error = { 'code' => 0, 'msg' => '' }

                # send a request to solr /select
                solrReply = @rSolrObj.get op, :params => VOYLLA_DEFAULT_QUERY_PARAMS.merge(queryParams)

                responseHeader = solrReply['responseHeader']
		facetCounts = solrReply['facet_counts']
                if ( responseHeader['status'] == 0 )
                        docs = solrReply['response'] if solrReply.has_key?('response')
                        docs = solrReply['grouped'] if solrReply.has_key?('grouped')
                end

                rescue RSolr::Error => sE
                        error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

                rescue => e
                        puts e.inspect
                        error = { 'code' => -1, 'msg' => e.message }
                end

                return error, docs, responseHeader, facetCounts
        end

	private
	def queryCleaner(q)
		lq = q
		lq.strip!
		lq.downcase!
		lq.gsub!(/[^. :%+0-9A-Za-z]/, ' ')
		if defined?(lq) && lq != ''
			lq = CGI.unescape(lq)
			lq = CGI.unescape(lq)
		end
		lq.gsub!(/ +/, ' ')
		lq.strip!
		return lq
	end

	def queryCleaner1(q)
		lq = q
		lq.strip!
		lq.downcase!
		if defined?(lq) && lq != ''
			lq = CGI.unescape(lq)
			lq = CGI.unescape(lq)
		end
		lq.gsub!(/ +/, ' ')
		lq.strip!
		return lq
	end

	private
	def parseDoc(doc)
		doc.delete('productTags') if doc.has_key?('productTags')
		if doc.has_key?('productTagNames') && !doc['productTagNames'].nil? && doc.has_key?('productTagValues') && !doc['productTagValues'].nil?
			tags = {}
			tagNames = doc['productTagNames']
			tagValues = doc['productTagValues']
			tagNames.each_with_index do |tagName, tagIndex|
				tags[tagName] = [] if !tags.has_key?(tagName)
				tags[tagName].push(tagValues[tagIndex])
			end
			doc['tags'] = tags
		end

		doc.delete('productPromos') if doc.has_key?('productPromos')
		if doc.has_key?('productPromoNames') && !doc['productPromoNames'].nil? && doc.has_key?('productPromoValues') && !doc['productPromoValues'].nil?
			promos = {}
			promoNames = doc['productPromoNames']
			promoValues = doc['productPromoValues']
			promoNames.each_with_index do |promoName, promoIndex|
				promos[promoName] = [] if !promos.has_key?(promoName)
				promos[promoName].push(promoValues[promoIndex])
			end
			doc['promos'] = promos
		end

		doc['assetDetails'] = {}
		if doc.has_key?('productAssetDetailsJson')
			assetDetails = doc['productAssetDetailsJson']
			assetDetails.each do |assetDetailStr|
				assetDetail = JSON.parse(assetDetailStr)
				doc['assetDetails'][assetDetail['type']] = [] if !doc['assetDetails'].has_key?(assetDetail['type'])
				doc['assetDetails'][assetDetail['type']].push(assetDetail)
			end
			doc.delete('productAssetDetailsJson')
		end

		variantOptions = {}
		puts doc['variantOptionJson']
		if doc.has_key?('variantOptionJson')
			doc['variantOptionJson'].each do |variantOptionJsonStr|
				variantOption = JSON.parse(variantOptionJsonStr)
				variantOptions[variantOption['variantId']] = [] if !variantOptions.has_key?(variantOption['variantId'])
				variantOptions[variantOption['variantId']].push({'option_type' => variantOption['option_type'], 'option_type_value' => variantOption['option_type_value']})
			end
			doc.delete('variantOptionJson')
		end

		if doc.has_key?('variantId')
			variants = []
			doc['variantId'].each_with_index do |vId, vIndex|
				variants.push({'id' => vId, 'sku' => doc['variantSku'][vIndex], 'isMaster' => doc['variantIsMaster'][vIndex], 'vStock' => doc['vStock'][vIndex], 'cPrice' => doc['cPrice'][vIndex], 'Price' => doc['Price'][vIndex], 'options' => variantOptions[vId]})

				if doc['variantIsMaster'][vIndex]
					doc['masterVariant'] = variants.last
				end
			end

			doc.delete('variantId')
			doc.delete('variantSku')
			doc.delete('variantIsMaster')
			doc.delete('vStock')
			doc.delete('cPrice')
			doc.delete('Price')	

			doc['variants'] = variants
		end

		return doc
	end

	private
	def applyFieldMap(doc)
		VOYLLA_FIELD_MAP.each do |fromField, toField|
			doc[toField] = doc[fromField]
		end

		return doc
	end

	private
	def parseResults(docs, isGroupedResult = false, removeDuplicates = false)
		idList = {}

		if isGroupedResult
			docResults = {}
			groups = docs

			groups.each do |group|
				docResults[group['groupValue']] = [] if !docResults.has_key?(group['groupValue'])

				group['doclist']['docs'].each do |doc|
					next if removeDuplicates && idList.has_key?(doc[VOYLLA_PRODUCTID_FIELD])

					docResults[group['groupValue']].push(parseDoc(applyFieldMap(doc)))

					idList[doc[VOYLLA_PRODUCTID_FIELD]] = true if removeDuplicates
				end
			end
		else
			docResults = []

			docs.each do |doc|

				next if removeDuplicates && idList.has_key?(doc[VOYLLA_PRODUCTID_FIELD])

				docResults.push(parseDoc(applyFieldMap(doc)))

				idList[doc[VOYLLA_PRODUCTID_FIELD]] = true if removeDuplicates
			end
		end

		return docResults
	end

	private
	def parseFacets(facet_counts,currency,conversion=1)
		count_hash = Hash[facet_counts["facet_fields"].map { |k, v| [k, Hash[*v]] }]				#converting the array to hash
		if currency == "INR"
			range_stats = facet_counts["facet_ranges"]["product_selling_price"]
		else
			range_stats = facet_counts["facet_ranges"]["product_selling_price_in_dollars"]
		end
		if !range_stats.nil?
			range_gap = range_stats["gap"]															##bucket size
			after = range_stats["after"]															##products after the last bucket
			range_counts = Hash[Hash[*range_stats["counts"].map(&:to_i)].sort]

			price_labels = ProductFilters.price_bucket_filters(currency)[:labels]

			keys = range_counts.keys
			range_counts[(keys.last + range_gap).to_i] = after
			keys = range_counts.keys
			values = price_labels.values
			length = keys.length

			range_counts_hash = {}
			keys.each_with_index do |key,i|															##map facet range buckets to price filter buckets
				if i < length - 1
					if currency == "INR"
						bucket = key.to_s + " TO " + (keys[i+1]-1).to_s
					else
						bucket = key.to_s + " TO " + keys[i+1].to_s
					end
					if (values.member? bucket)
						range_counts_hash[bucket] = range_counts[key]
					else
						if i < length - 2
							if currency == "INR"
								bucket = key.to_s + " TO " + (keys[i+2]-1).to_s							###assuming bucket size is multiple of gap
							else
								bucket = key.to_s + " TO " + (keys[i+2]).to_s
							end
							if (values.member? bucket)
								range_counts_hash[bucket] = range_counts[key] + range_counts[keys[i+1]]
							end
						end
					end
				elsif i == length -1
					bucket = key.to_s + " TO *"
					range_counts_hash[bucket] = range_counts[key]
				end
			end

			count_hash["product_selling_price"] = range_counts_hash

		else
			count_hash["product_selling_price"] = {}			
		end

		disc_counts = count_hash["product_discount_bucket"]							####a given discount bucket would also contain products in higher buckets (10% or more etc)
		if !disc_counts.nil?
			disc_keys = disc_counts.keys
			disc_counts_hash = {}
			disc_keys.each{ |dk|
				dv = disc_keys.select{ |key| key>=dk}.map{|d| disc_counts[d]}.sum			####sum the counts of all buckets with value >= given bucket
				disc_counts_hash[dk] = dv
			}
			count_hash["product_discount_bucket"] = disc_counts_hash
		else
			count_hash["product_discount_bucket"] = {}
		end

		return count_hash
	end

	private
	def queryDocs(q, start = 0, rows = VOYLLA_DEFAULT_ROWS, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# clean query
		q = queryCleaner(q)
		puts q

		# prepare query
		queryParams = {:q => q, :fq => VOYLLA_DEFAULT_FILTER, :start => start, :rows => rows, :fl => fields, :sort => sortOrder}

		# send query to Solr
		(error, response, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader
	end

	private
	def queryTagDocs(q, t, start = 0, rows = 250, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# clean query
		q = queryCleaner1(q)
		puts q

		# prepare query
		queryParams = {:q => "productTagValues:"+q, :fq => "+productAvailableDateTs:[* TO NOW/DAY], +pStock:[1 TO *], +productTaxonomyName:"+t, :start => start, :rows => rows, :fl => fields, :sort => sortOrder}

		# send query to Solr
		(error, response, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader
	end

	private
	def queryMoreDocs(q, num, taxon, start = 0, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# clean query
		q = queryCleaner(q)
		puts q

		# prepare query
		filterQuery = '+pStock:[1 TO *], +productTaxonomyName:'+taxon
		queryParams = {:q => q, :fq => filterQuery, :start => start, :rows => num, :fl => fields, :sort => sortOrder}

		# send query to Solr
		(error, response, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader
	end

	private
        def facetedQueryDocs(q, facet, facetQuery, facetField, start = 0, rows = VOYLLA_DEFAULT_ROWS, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
                begin
                error = { 'code' => 0, 'msg' => '' }

                # clean query
                q = queryCleaner(q)
                puts q

                # prepare query
                queryParams = { :q => q, :fq => VOYLLA_DEFAULT_FILTER, :start => start, :rows => rows, :fl => fields, :sort => sortOrder, :facet=>facet, 'facet.query'=>facetQuery, 'facet.field'=>facetField}

                # send query to Solr
                (error, response, responseHeader, facetCounts) = facetedQuerySolr('select', queryParams)

                if ( error['code'] == 0 && response['numFound'] > 0 )
                        numDocs = response['numFound']
                        docs = response['docs']

                        docs = parseResults(docs, false, true)
                else
                        numDocs = 0
                end

                rescue RSolr::Error => sE
                        numDocs = 0
                        error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

                rescue => e
                        numDocs = 0
                        puts e.inspect
                        error = { 'code' => -1, 'msg' => e.message }
                end

                return error, numDocs, docs, responseHeader, facetCounts
        end

	private
	def facetResultDocs(q, facetField, facetFieldValue, start = 0, rows = VOYLLA_DEFAULT_ROWS, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
                begin
                error = { 'code' => 0, 'msg' => '' }

                # clean query
                q = queryCleaner(q)
                puts q

                # prepare query
                queryParams = {:q => q, :fq => facetField+":"+facetFieldValue, :start => start, :rows => rows, :fl => fields, :sort => sortOrder, :facet=>'true', 'facet.query'=>q, 'facet.field'=>facetField}

                # send query to Solr
                (error, response, responseHeader) = querySolr('select', queryParams)

                if ( error['code'] == 0 && response['numFound'] > 0 )
                        numDocs = response['numFound']
                        docs = response['docs']

                        docs = parseResults(docs, false, true)
                else
                        numDocs = 0
                end

                rescue RSolr::Error => sE
                        numDocs = 0
                        error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

                rescue => e
                        numDocs = 0
                        puts e.inspect
                        error = { 'code' => -1, 'msg' => e.message }
                end

                return error, numDocs, docs, responseHeader
	end

	private
	def queryMLT(q, price, num, start = 0, rows = VOYLLA_DEFAULT_ROWS, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		puts q

		# prepare query
		#fq = VOYLLA_DEFAULT_FILTER + ["product_selling_price:[#{price*1} TO *]"]
		fq = VOYLLA_DEFAULT_FILTER
		queryParams = {:q => "#{VOYLLA_DOCID_FIELD}:#{q}", :fq => fq, :start => 0, :rows => num, :fl => VOYLLA_PRODUCTID_FIELD, :sort => sortOrder, :'mlt.fl' => VOYLLA_DEFAULT_MLT_FIELDS, :'mlt.count' => VOYLLA_DEFAULT_MLT_RESULTS_COUNT}

		# send query to Solr
		(error, response, responseHeader) = querySolr('mlt', queryParams)

		if ( error['code'] == 0 && response['numFound'] > 0 )
			numDocs = response['numFound']
			docs = response['docs']

			docs = parseResults(docs, false, true)
		else
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numDocs = 0
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, docs, responseHeader
	end

	private
	def queryGroups(q, groupByField, start = 0, rows = VOYLLA_DEFAULT_ROWS, fields = VOYLLA_DEFAULT_FIELDS, sortOrder = VOYLLA_DEFAULT_SORT_ORDER, groupSortOrder = VOYLLA_DEFAULT_SORT_ORDER)
		begin
		error = { 'code' => 0, 'msg' => '' }

		# clean query
		q = queryCleaner(q)
		puts q

		# prepare query
		queryParams = {:q => q, :fq => VOYLLA_DEFAULT_FILTER, :start => start, :rows => rows, :fl => fields, :sort => sortOrder, :group => true, :'group.ngroups' => true, :'group.field' => groupByField, :'group.sort' => groupSortOrder, :'group.limit' => 4 }

		# send request to Solr
		(error, grouped, responseHeader) = querySolr('select', queryParams)

		if ( error['code'] == 0 && grouped.has_key?(groupByField) && grouped[groupByField]['ngroups'] > 0 )
			numDocs = grouped[groupByField]['matches']
			numGroups = grouped[groupByField]['ngroups']
			groups = grouped[groupByField]['groups']

			groups = parseResults(groups, true, true)
		else
			numGroups = 0
			numDocs = 0
		end

		rescue RSolr::Error => sE
			numGroups = 0
			numDocs = 0
			puts sE.inspect
			error = { 'code' => sE.response[:status], 'msg' => sE.to_s }

		rescue => e
			numGroups = 0
			numDocs = 0
			puts e.inspect
			error = { 'code' => -1, 'msg' => e.message }
		end

		return error, numDocs, numGroups, groups, responseHeader
	end

	public
	def searchByTaxonomy(q)
		queryGroups(q, VOYLLA_TAXONOMY_FIELD_NAME)
	end

	public
	def searchById(id)
		return queryDocs("id:%{id}")
	end

	public
	def search(q)
		return queryDocs(q)
	end

	public
	def searchTags(q,t)
		return queryTagDocs(q,t)
	end

	public
	def filterSearch(q,t,c)
		return queryFilterTagDocs(q,t,c)
	end

	public
	def filterTextSearch(q,c)
		return queryFilterDocs(q,c)
	end

	public 
	def relatedProducts(taxon,type,price,num)
		return queryRelatedProducts(taxon,type,price,num)
	end

	public
	def recommendedProducts(taxon, collection, type, rows)
		return queryRecommendedProducts(taxon, collection, type, rows)
	end

	public
	def searchPromos(q,c)
		return queryFilterPromoDocs(q,c)
	end

	public
	def searchMore(q, num, taxon)
		return queryMoreDocs(q, num, taxon)
	end

	def facetedSearch(q, facet, facetQuery, facetField)
		return facetedQueryDocs(q, facet, facetQuery, facetField)
	end

	def facetResults(q, facetField, facetFieldValue)
		return facetResultDocs(q, facetField, facetFieldValue)
	end

	public
	def searchMLT(id, price, num)
		return queryMLT(id, price, num)
	end
end
=begin
re = RecommendationEngine.new
re.connect

while (1)
	print 'Query? '
	q = gets.chomp
	facet = "true"
	facetQuery = q
	facetField = "productTaxonomyName"

	exit if q == ''

	numGroups = 0
	#(error, numDocs, numGroups, groups, responseHeader) = re.searchByTaxonomy(q)
	#(error, numDocs, docs, responseHeader, facetCounts) = re.facetedSearch(q, facet, facetQuery, facetField)
	(error, numDocs, docs, responseHeader) = re.facetResults(q, facetField, facetFieldValue)
	#(error, numDocs, docs, responseHeader) = re.searchMLT(q)

	print "\n> Hits: ", numDocs
        print ' (Groups: ', numGroups, ')' if numGroups > 0
	print "\n"
	puts facetCounts

	if ( numGroups > 0 )
		groups.each do |group, docs|
			puts "\n"
			puts "#{group} =>\n"
			docs.each do |doc|
				puts "\n"
				doc.each do |key, value|
					puts "#{key}: #{value}"
				end
			end
		end
	elsif ( numDocs > 0 )
		puts "\n"
		docs.each do |doc|
			doc.each do |key, value|
#				puts "#{key}: #{value}"
			end
		end
	end

	#puts error.inspect

	if ( error && error['code'] > 0 )
		puts error['msg']
	end

	print 'facet? '
        facetQuery = gets.chomp
		
end
=end
