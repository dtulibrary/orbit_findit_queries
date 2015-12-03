require 'active_support/all'
require 'awesome_print'
require 'rsolr'
require 'tilt'
require 'debugger'

def cleanup(sentence)
  sentence.split.select{|w| w.match(/^[[:alpha:]]+$/)}.join(' ')
end

url = 'http://localhost:8983/solr/metastore'

filters = ['format:article', 'access_ss:dtu', 'pub_date_tis:2015']
fields  = 'id,title_ts,journal_title_ts,conf_title_ts,author_ts,affiliation_ts,pub_date_tis,journal_vol_ssf,journal_issue_ssf,journal_page_ssf,cluster_id_ss,source_id_ss'

departments = {}

if ARGV.count > 0
  doc_ids    = Set.new
  found_ids  = Set.new 
  solr = RSolr.connect :url => url

  Dir.glob("found/*.json").each do |f|
    found = JSON.parse(File.read(f))
    found.each do |_, docs| 
      docs.each do |id, _| 
        found_ids.add(id)
      end
    end
  end


  # loop through each department and iterate over queries in file
  # execute each query and return 
  ARGV.each do |f|
    department = File.basename(f, '.txt')
    departments[department] = {}

    queries = File.readlines(f).map(&:chomp).split("").map{|q| q.join(' ')}.reject{|q| q.blank?}
    
    queries.each do |q|
      cursorMark = '*'
      loop do
        result = solr.get('toshokan', :params => {:fq => filters + ['-source_ss:orbit'],
            :q => q, :cursorMark => cursorMark, :rows => 100, :sort => 'id asc', 
            :fl => fields, :facet => false})
        docs = result['response']['docs']

        if cursorMark == '*'
          print [q, result['response']['numFound']].inspect
        else 
          print '.'
        end

        docs.each do |doc|
          next if doc_ids.include? doc['id']
          next if found_ids.include? doc['id']
          doc_ids.add doc['id']
          departments[department][doc['id']] = doc
        end
        
        break if result['nextCursorMark'] == cursorMark
        cursorMark = result['nextCursorMark']
      end
      puts
    end

  end

  File.open('candidates.json', 'w') do |f| 
    f.write(departments.to_json)
  end

else

  File.open('candidates.json') do |f|
    departments = JSON.parse(f.read)
  end

end

if ARGV.count > 0
  solr = RSolr.connect :url => url
  departments.sort_by{|dep, _| dep}.each do |dep, docs|
    print [dep, docs.count].inspect
    docs.each do |id, doc|
      title = doc['title_ts'].first
      authors = doc['author_ts'] || []
      journal_title = doc['journal_title_ts'].try(:first) || ""
      conf_title = doc['conf_title_ts'].try(:first) || ""

      author_words = authors.map{|a| a.split(',').first}[0..10] || []

      q = ""
      q += " title_ts:(#{cleanup(title)})"
      q += " author_ts:(#{author_words.join(' ')})" 
      q += " journal_title_ts:(#{cleanup(journal_title)})" if !journal_title.blank?
      q += " conf_title_ts:(#{cleanup(conf_title)})" if !conf_title.blank?
      doc[:query] = q

      result = solr.get('toshokan', :params => {:fq => filters + ['source_ss:orbit'], :q => q, 'q.op' => 'OR', :mm => '75%', :qf => '*', :rows => 1, :sort => 'score desc', :fl => fields})
      doc[:duplicate] = result['response']['docs'].first
      doc[:has_duplicate] = (doc[:duplicate] ? 0 : 1)
      doc[:author_words] = author_words

      print doc[:duplicate] ? '+' : '-'
    end
    puts
  end

  File.open('candidates.json', 'w') do |f| 
    f.write(departments.to_json)
  end

else

  File.open('candidates.json') do |f|
    departments = JSON.parse(f.read)
  end

end

FileUtils.rm_f Dir.glob('Orbit-*.html')

template = Tilt::ERBTemplate.new("layout.erb")
departments.each do |dep, docs|
  next if docs.empty?
  File.open("Orbit-#{dep}.html", 'w') do |file|
    file.write template.render(Object.new, :title => dep) {
      docs.values.sort_by{ |d| [d['duplicate'].nil? ? 0 : 1, d['title_ts'].first] }.map.with_index { |r, i|
        Tilt::ERBTemplate.new("record.erb").render(Object.new, :record => r.with_indifferent_access, :index => i)
      }.join("\n")
    }
  end
end

