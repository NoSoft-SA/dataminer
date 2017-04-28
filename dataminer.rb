require 'roda'
require 'rom'
require 'rom-sql'
require 'rom-repository'

require 'crossbeams/dataminer_interface'
require './lib/db_connections'

DB = DBConnections.new

class Dataminer < Roda
  plugin :render
  plugin :assets, css: 'style.scss'
  plugin :public # serve assets from public folder.
  plugin :content_for, append: true
  plugin :indifferent_params

  use Crossbeams::DataminerInterface::App, url_prefix: 'dataminer/',
    dm_reports_location: File.join(File.dirname(__FILE__), '..', '..', 'roda_frame', 'reports'),
    dm_js_location: 'js', dm_css_location: 'css', db_connection: DB.base

  route do |r|

    r.assets unless ENV['RACK_ENV'] == 'production'

    r.public

    r.root do
      r.redirect '/dataminer/'
      # view('home')
    end
  end
end