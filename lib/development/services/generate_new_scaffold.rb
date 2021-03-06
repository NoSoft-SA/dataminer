# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize

class GenerateNewScaffold < BaseService
  include UtilityFunctions
  attr_accessor :opts

  class ScaffoldConfig
    attr_reader :inflector, :table, :singlename, :new_applet, :applet, :program,
                :table_meta, :label_field, :short_name, :has_short_name, :program_text,
                :nested_route

    def initialize(params, roda_class_name)
      @roda_class_name  = roda_class_name
      @inflector        = Dry::Inflector.new
      @table            = params[:table]
      @singlename       = @inflector.singularize(params[:short_name])
      @has_short_name   = params[:short_name] != params[:table]
      @applet           = params[:applet]
      @new_applet       = @applet == 'other'
      @applet           = params[:other] if @applet == 'other'
      @program_text     = params[:program].strip
      @program          = @program_text.tr(' ', '_')
      @table_meta       = TableMeta.new(@table)
      @label_field      = params[:label_field] || @table_meta.likely_label_field
      @shared_repo_name = params[:shared_repo_name]
      @nested_route     = params[:nested_route_parent].empty? ? nil : params[:nested_route_parent]
    end

    def classnames
      modulename    = "#{@applet.split('_').map(&:capitalize).join}App"
      classname     = @inflector.camelize(@singlename)
      applet_klass  = @inflector.camelize(@applet)
      program_klass = @inflector.camelize(@program)
      {
        roda_class: @roda_class_name,
        module: modulename,
        class: classname,
        applet: applet_klass,
        program: program_klass,
        text_name: @inflector.singularize(@table).split('_').map(&:capitalize).join(' '),
        schema: "#{classname}Schema",
        repo: "#{@shared_repo_name.nil? || @shared_repo_name.empty? ? classname : @inflector.camelize(@shared_repo_name.sub(/Repo$/, ''))}Repo",
        namespaced_repo: "#{modulename}::#{@shared_repo_name.nil? || @shared_repo_name.empty? ? classname : @inflector.camelize(@shared_repo_name.sub(/Repo$/, ''))}Repo",
        interactor: "#{classname}Interactor",
        namespaced_interactor: "#{modulename}::#{classname}Interactor",
        view_prefix: "#{applet_klass}::#{program_klass}::#{classname}"
      }
    end

    def filenames
      repofile = if @shared_repo_name
                   @inflector.underscore(@shared_repo_name.sub(/Repo$/, ''))
                 else
                   @singlename
                 end
      {
        applet: "lib/applets/#{@applet}_applet.rb",
        dm_query: "grid_definitions/dataminer_queries/#{@table}.yml",
        list: "grid_definitions/lists/#{@table}.yml",
        search: "grid_definitions/searches/#{@table}.yml",
        repo: "lib/#{@applet}/repositories/#{repofile}_repo.rb",
        inter: "lib/#{@applet}/interactors/#{@singlename}_interactor.rb",
        entity: "lib/#{@applet}/entities/#{@singlename}.rb",
        validation: "lib/#{@applet}/validations/#{@singlename}_schema.rb",
        route: "routes/#{@applet}/#{@program}.rb",
        uirule: "lib/#{@applet}/ui_rules/#{@singlename}_rule.rb",
        view: {
          new: "lib/#{@applet}/views/#{@singlename}/new.rb",
          edit: "lib/#{@applet}/views/#{@singlename}/edit.rb",
          show: "lib/#{@applet}/views/#{@singlename}/show.rb"
        },
        test: {
          interactor: "lib/#{@applet}/test/interactors/test_#{@singlename}_interactor.rb",
          repo: "lib/#{@applet}/test/repositories/test_#{repofile}_repo.rb",
          route: "test/routes/#{@applet}/#{@program}/test_#{@singlename}_routes.rb"
        }
      }
    end
  end

  # TODO: dry-validation: type to pre-strip strings...
  def initialize(params, roda_class_name)
    @opts = ScaffoldConfig.new(params, roda_class_name)
  end

  def call
    sources = { opts: opts, paths: @opts.filenames }

    report               = QueryMaker.call(opts)
    sources[:query]      = wrapped_sql_from_report(report)
    sources[:dm_query]   = DmQueryMaker.call(report, opts)
    sources[:list]       = ListMaker.call(opts)
    sources[:search]     = SearchMaker.call(opts)
    sources[:repo]       = RepoMaker.call(opts)
    sources[:entity]     = EntityMaker.call(opts)
    sources[:inter]      = InteractorMaker.call(opts)
    sources[:validation] = ValidationMaker.call(opts)
    sources[:uirule]     = UiRuleMaker.call(opts)
    sources[:view]       = ViewMaker.call(opts)
    sources[:route]      = RouteMaker.call(opts)
    sources[:menu]       = MenuMaker.call(opts)
    sources[:test]       = TestMaker.call(opts)
    sources[:applet]     = AppletMaker.call(opts) if opts.new_applet

    sources
  end

  private

  def wrapped_sql_from_report(report)
    width = 120
    ar = report.runnable_sql.gsub(/from /i, "\nFROM ").gsub(/where /i, "\nWHERE ").gsub(/(left outer join |left join |inner join |join )/i, "\n\\1").split("\n")
    ar.map { |a| a.scan(/\S.{0,#{width - 2}}\S(?=\s|$)|\S+/).join("\n") }.join("\n")
  end

  class TableMeta
    attr_reader :columns, :column_names, :foreigns, :col_lookup, :fk_lookup, :indexed_columns

    DRY_TYPE_LOOKUP = {
      integer: 'Types::Int',
      string: 'Types::String',
      boolean: 'Types::Bool',
      float: 'Types::Float',
      datetime: 'Types::DateTime',
      date: 'Types::Date',
      decimal: 'Types::Decimal',
      integer_array: 'Types::Array',
      string_array: 'Types::Array',
      jsonb: 'Types::Hash'
    }.freeze

    VALIDATION_EXPECT_LOOKUP = {
      integer: '(:int?)',
      string: '(:str?)',
      boolean: '(:bool?)',
      datetime: '(:date_time?)',
      date: '(:date?)',
      time: '(:time?)',
      float: '(:float?)',
      decimal: '(:decimal?)',
      jsonb: '(:hash?)',
      integer_array: nil, # ' { each(:int?) }',
      string_array: nil # ' { each(:str?) }'
    }.freeze

    VALIDATION_TYPE_LOOKUP = {
      integer: ':int',
      string: 'Types::StrippedString',
      boolean: ':bool',
      datetime: ':date_time',
      date: ':date',
      time: ':time',
      float: ':float',
      decimal: ':decimal',
      jsonb: ':hash',
      integer_array: ':array',
      string_array: ':array'
    }.freeze

    VALIDATION_ARRAY_LOOKUP = {
      integer_array: ' { each(:int?) }',
      string_array: ' { each(:str?) }'
    }.freeze

    def initialize(table)
      repo             = DevelopmentApp::DevelopmentRepo.new
      @columns         = repo.table_columns(table)
      @column_names    = repo.table_col_names(table)
      @indexed_columns = repo.indexed_columns(table)
      @foreigns        = repo.foreign_keys(table)
      @col_lookup      = Hash[@columns]
      @fk_lookup       = {}
      @foreigns.each { |hs| hs[:columns].each { |c| @fk_lookup[c] = { key: hs[:key], table: hs[:table] } } }
    end

    def likely_label_field
      col_name = nil
      columns.each do |this_name, attrs|
        next if this_name == :id
        next if this_name.to_s.end_with?('_id')
        next unless attrs[:type] == :string
        col_name = this_name
        break
      end
      col_name || 'id'
    end

    def columns_without(ignore_cols)
      @column_names.reject { |c| ignore_cols.include?(c) }
    end

    def column_dry_type(column)
      DRY_TYPE_LOOKUP[@col_lookup[column][:type]] || "Types::??? (#{@col_lookup[column][:type]})"
    end

    def column_dry_validation_type(column)
      VALIDATION_TYPE_LOOKUP[@col_lookup[column][:type]] || "Types::??? (#{@col_lookup[column][:type]})"
    end

    def column_dry_validation_array_extra(column)
      VALIDATION_ARRAY_LOOKUP[@col_lookup[column][:type]]
    end

    def column_dry_validation_expect_type(column)
      VALIDATION_EXPECT_LOOKUP[@col_lookup[column][:type]] || "(Types::??? (#{@col_lookup[column][:type]}))"
    end

    def active_column_present?
      @column_names.include?(:active)
    end
  end

  class InteractorMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      <<~RUBY
        # frozen_string_literal: true

        module #{opts.classnames[:module]}
          class #{opts.classnames[:interactor]} < BaseInteractor
            def repo
              @repo ||= #{opts.classnames[:repo]}.new
            end

            def #{opts.singlename}(id)
              repo.find_#{opts.singlename}(id)
            end

            def validate_#{opts.singlename}_params(params)
              #{opts.classnames[:schema]}.call(params)
            end

            def create_#{opts.singlename}(#{needs_id}params)#{add_parent_to_params}
              res = validate_#{opts.singlename}_params(params)
              return validation_failed_response(res) unless res.messages.empty?
              id = nil
              DB.transaction do
                id = repo.create_#{opts.singlename}(res)
                log_transaction
              end
              instance = #{opts.singlename}(id)
              success_response("Created #{opts.classnames[:text_name].downcase} \#{instance.#{opts.label_field}}",
                               instance)
            rescue Sequel::UniqueConstraintViolation
              validation_failed_response(OpenStruct.new(messages: { #{opts.label_field}: ['This #{opts.classnames[:text_name].downcase} already exists'] }))
            end

            def update_#{opts.singlename}(id, params)
              res = validate_#{opts.singlename}_params(params)
              return validation_failed_response(res) unless res.messages.empty?
              DB.transaction do
                repo.update_#{opts.singlename}(id, res)
                log_transaction
              end
              instance = #{opts.singlename}(id)
              success_response("Updated #{opts.classnames[:text_name].downcase} \#{instance.#{opts.label_field}}",
                               instance)
            end

            def delete_#{opts.singlename}(id)
              name = #{opts.singlename}(id).#{opts.label_field}
              DB.transaction do
                repo.delete_#{opts.singlename}(id)
                log_transaction
              end
              success_response("Deleted #{opts.classnames[:text_name].downcase} \#{name}")
            end
          end
        end
      RUBY
    end

    private

    def needs_id
      opts.nested_route ? 'parent_id, ' : ''
    end

    def add_parent_to_params
      parent_id_name = opts.inflector.foreign_key(opts.inflector.singularize(opts.nested_route)) if opts.nested_route
      opts.nested_route ? "\n      params[:#{parent_id_name}] = parent_id" : ''
    end
  end

  class RepoMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      alias_active   = opts.has_short_name ? "#{UtilityFunctions.newline_and_spaces(21)}alias: :#{opts.singlename}," : ''
      alias_inactive = opts.has_short_name ? "#{UtilityFunctions.newline_and_spaces(26)}alias: :#{opts.singlename}," : ''
      if @opts.table_meta.active_column_present?
        <<~RUBY
          # frozen_string_literal: true

          module #{opts.classnames[:module]}
            class #{opts.classnames[:repo]} < BaseRepo
              build_for_select :#{opts.table},#{alias_active}
                               label: :#{opts.label_field},
                               value: :id,
                               order_by: :#{opts.label_field}
              build_inactive_select :#{opts.table},#{alias_inactive}
                                    label: :#{opts.label_field},
                                    value: :id,
                                    order_by: :#{opts.label_field}

              crud_calls_for :#{opts.table}, name: :#{opts.singlename}, wrapper: #{opts.classnames[:class]}
            end
          end
        RUBY
      else
        <<~RUBY
          # frozen_string_literal: true

          module #{opts.classnames[:module]}
            class #{opts.classnames[:repo]} < BaseRepo
              build_for_select :#{opts.table},#{alias_active}
                               label: :#{opts.label_field},
                               value: :id,
                               no_active_check: true,
                               order_by: :#{opts.label_field}

              crud_calls_for :#{opts.table}, name: :#{opts.singlename}, wrapper: #{opts.classnames[:class]}
            end
          end
        RUBY
      end
    end
  end

  class EntityMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      attr = columnise
      <<~RUBY
        # frozen_string_literal: true

        module #{opts.classnames[:module]}
          class #{opts.classnames[:class]} < Dry::Struct
            #{attr.join("\n    ")}
          end
        end
      RUBY
    end

    private

    def columnise
      attr = []
      opts.table_meta.columns_without(%i[created_at updated_at active]).each do |col|
        attr << "attribute :#{col}, #{opts.table_meta.column_dry_type(col)}"
      end
      attr
    end
  end

  class ValidationMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      attr = columnise
      <<~RUBY
        # frozen_string_literal: true

        module #{opts.classnames[:module]}
          #{opts.classnames[:schema]} = Dry::Validation.Form do
            configure { config.type_specs = true }

            #{attr.join("\n    ")}
          end
        end
      RUBY
    end

    private

    def columnise
      attr = []
      opts.table_meta.columns_without(%i[created_at updated_at active]).each do |col|
        detail = opts.table_meta.col_lookup[col]
        fill_opt = detail[:allow_null] ? 'maybe' : 'filled'
        max = detail[:max_length] && detail[:max_length] < 200 ? "max_size?: #{detail[:max_length]}" : nil
        rules = [opts.table_meta.column_dry_validation_expect_type(col), max, opts.table_meta.column_dry_validation_array_extra(col)].compact.join(', ')
        attr << if col == :id
                  "optional(:#{col}, #{opts.table_meta.column_dry_validation_type(col)}).#{fill_opt}#{rules}"
                else
                  "required(:#{col}, #{opts.table_meta.column_dry_validation_type(col)}).#{fill_opt}#{rules}"
                end
      end
      attr
    end
  end

  class ListMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      list = { dataminer_definition: opts.table }
      list[:actions] = []
      list[:actions] << { url: "/#{opts.applet}/#{opts.program}/#{opts.table}/$:id$",
                          text: 'view',
                          icon: 'view-show',
                          title: 'View',
                          popup: true }
      list[:actions] << { url: "/#{opts.applet}/#{opts.program}/#{opts.table}/$:id$/edit",
                          text: 'edit',
                          icon: 'edit',
                          title: 'Edit',
                          popup: true }
      list[:actions] << { url: "/#{opts.applet}/#{opts.program}/#{opts.table}/$:id$",
                          text: 'delete',
                          icon: 'delete',
                          is_delete: true,
                          popup: true }
      list[:page_controls] = []
      list[:page_controls] << { control_type: :link,
                                url: "/#{opts.applet}/#{opts.program}/#{opts.table}/new",
                                text: "New #{opts.classnames[:text_name]}",
                                style: :button,
                                behaviour: :popup }
      list.to_yaml
    end
  end

  class SearchMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      search = { dataminer_definition: opts.table }
      search[:actions] = []
      search[:actions] << { url: "/#{opts.applet}/#{opts.program}/#{opts.table}/$:id$",
                            text: 'view',
                            icon: 'view-show',
                            title: 'View',
                            popup: true }
      search[:actions] << { url: "/#{opts.applet}/#{opts.program}/#{opts.table}/$:id$/edit",
                            text: 'edit',
                            icon: 'edit',
                            title: 'Edit',
                            popup: true }
      search[:actions] << { url: "/#{opts.applet}/#{opts.program}/#{opts.table}/$:id$",
                            text: 'delete',
                            icon: 'delete',
                            is_delete: true,
                            popup: true }
      search[:page_controls] = []
      search[:page_controls] << { control_type: :link,
                                  url: "/#{opts.applet}/#{opts.program}/#{opts.table}/new",
                                  text: "New #{opts.classnames[:text_name]}",
                                  style: :button,
                                  behaviour: :popup }
      search.to_yaml
    end
  end

  class RouteMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      <<~RUBY
        # frozen_string_literal: true

        # rubocop:disable Metrics/ClassLength
        # rubocop:disable Metrics/BlockLength

        class #{opts.classnames[:roda_class]} < Roda
          route '#{opts.program}', '#{opts.applet}' do |r|
            # #{opts.table.upcase.tr('_', ' ')}
            # --------------------------------------------------------------------------
            r.on '#{opts.table}', Integer do |id|
              interactor = #{opts.classnames[:namespaced_interactor]}.new(current_user, {}, { route_url: request.path }, {})

              # Check for notfound:
              r.on !interactor.exists?(:#{opts.table}, id) do
                handle_not_found(r)
              end

              r.on 'edit' do   # EDIT
                check_auth!('#{opts.program_text}', 'edit')
                show_partial { #{opts.classnames[:view_prefix]}::Edit.call(id) }
              end
              r.is do
                r.get do       # SHOW
                  check_auth!('#{opts.program_text}', 'read')
                  show_partial { #{opts.classnames[:view_prefix]}::Show.call(id) }
                end
                r.patch do     # UPDATE
                  return_json_response
                  res = interactor.update_#{opts.singlename}(id, params[:#{opts.singlename}])
                  if res.success
                    #{update_grid_row.gsub("\n", "\n            ").sub(/            \Z/, '').sub(/\n\Z/, '')}
                  else
                    content = show_partial { #{opts.classnames[:view_prefix]}::Edit.call(id, form_values: params[:#{opts.singlename}], form_errors: res.errors) }
                    update_dialog_content(content: content, error: res.message)
                  end
                end
                r.delete do    # DELETE
                  return_json_response
                  check_auth!('#{opts.program_text}', 'delete')
                  res = interactor.delete_#{opts.singlename}(id)
                  delete_grid_row(id, notice: res.message)
                end
              end
            end

            #{new_create_routes.chomp.gsub("\n", "\n    ")}
          end
        end

        # rubocop:enable Metrics/ClassLength
        # rubocop:enable Metrics/BlockLength
      RUBY
    end

    def new_create_routes
      if opts.nested_route
        nested_new_routes
      else
        plain_new_routes
      end
    end

    def plain_new_routes
      <<~RUBY
        r.on '#{opts.table}' do
          interactor = #{opts.classnames[:namespaced_interactor]}.new(current_user, {}, { route_url: request.path }, {})
          r.on 'new' do    # NEW
            check_auth!('#{opts.program_text}', 'new')
            # FIXME: --- UNCOMMENT next line if this is called directly from a menu item
            # set_last_grid_url('/list/#{opts.table}', r)
            show_partial_or_page(r) { #{opts.classnames[:view_prefix]}::New.call(remote: fetch?(r)) }
          end
          r.post do        # CREATE
            res = interactor.create_#{opts.singlename}(params[:#{opts.singlename}])
            if res.success
              flash[:notice] = res.message
              redirect_to_last_grid(r)
            else
              re_show_form(r, res, url: '/#{opts.applet}/#{opts.program}/#{opts.table}/new') do
                #{opts.classnames[:view_prefix]}::New.call(form_values: params[:#{opts.singlename}],
                #{UtilityFunctions.spaces_from_string_lengths(11, opts.classnames[:view_prefix])}form_errors: res.errors,
                #{UtilityFunctions.spaces_from_string_lengths(11, opts.classnames[:view_prefix])}remote: fetch?(r))
              end
            end
          end
        end
      RUBY
    end

    def nested_new_routes
      <<~RUBY
        r.on '#{opts.nested_route}', Integer do |id|
          r.on '#{opts.table}' do
            interactor = #{opts.classnames[:namespaced_interactor]}.new(current_user, {}, { route_url: request.path }, {})
            r.on 'new' do    # NEW
              check_auth!('#{opts.program_text}', 'new')
              # FIXME: --- UNCOMMENT next line if this is called directly from a menu item
              # set_last_grid_url('/list/#{opts.table}', r)
              show_partial_or_page(r) { #{opts.classnames[:view_prefix]}::New.call(id, remote: fetch?(r)) }
            end
            r.post do        # CREATE
              res = interactor.create_#{opts.singlename}(id, params[:#{opts.singlename}])
              if res.success
                flash[:notice] = res.message
                redirect_to_last_grid(r)
              else
                re_show_form(r, res, url: "/#{opts.applet}/#{opts.program}/#{opts.nested_route}/\#{id}/#{opts.table}/new") do
                  #{opts.classnames[:view_prefix]}::New.call(id,
                  #{UtilityFunctions.spaces_from_string_lengths(11, opts.classnames[:view_prefix])}form_values: params[:#{opts.singlename}],
                  #{UtilityFunctions.spaces_from_string_lengths(11, opts.classnames[:view_prefix])}form_errors: res.errors,
                  #{UtilityFunctions.spaces_from_string_lengths(11, opts.classnames[:view_prefix])}remote: fetch?(r))
                end
              end
            end
          end
        end
      RUBY
    end

    def update_grid_row
      if opts.table_meta.columns_without(%i[id created_at updated_at active]).length > 3
        update_grid_row_many
      else
        update_grid_row_few
      end
    end

    def update_grid_row_many
      row_keys = opts.table_meta.columns_without(%i[id created_at updated_at active]).map(&:to_s).join("\n  ")
      <<~RUBY
        row_keys = %i[
          #{row_keys}
        ]
        update_grid_row(id, changes: select_attributes(res.instance, row_keys), notice: res.message)
      RUBY
    end

    def update_grid_row_few
      <<~RUBY
        update_grid_row(id, changes: { #{grid_refresh_fields} },
                            notice: res.message)
      RUBY
    end

    def grid_refresh_fields
      opts.table_meta.columns_without(%i[id created_at updated_at active]).map do |col|
        "#{col}: res.instance[:#{col}]"
      end.join(', ')
    end
  end

  class UiRuleMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      <<~RUBY
        # frozen_string_literal: true

        module UiRules
          class #{opts.classnames[:class]}Rule < Base
            def generate_rules
              @repo = #{opts.classnames[:namespaced_repo]}.new
              make_form_object
              apply_form_values

              common_values_for_fields common_fields

              set_show_fields if @mode == :show

              form_name '#{opts.singlename}'
            end

            def set_show_fields
              #{show_fields.join(UtilityFunctions.newline_and_spaces(6))}
            end

            def common_fields
              {
                #{common_fields.join(UtilityFunctions.comma_newline_and_spaces(8))}
              }
            end

            def make_form_object
              make_new_form_object && return if @mode == :new

              @form_object = @repo.find_#{opts.singlename}(@options[:id])
            end

            def make_new_form_object
              @form_object = OpenStruct.new(#{struct_fields.join(UtilityFunctions.comma_newline_and_spaces(36))})
            end
          end
        end
      RUBY
    end

    private

    def fields_to_use
      opts.table_meta.columns_without(%i[id created_at updated_at active])
    end

    def show_fields
      flds = []
      fields_to_use.each do |f|
        fk = opts.table_meta.fk_lookup[f]
        next unless fk
        tm = TableMeta.new(fk[:table])
        singlename  = opts.inflector.singularize(fk[:table].to_s)
        klassname   = opts.inflector.camelize(singlename)
        fk_repo = "#{opts.classnames[:module]}::#{klassname}Repo"
        code = tm.likely_label_field
        flds << "# #{f}_label = #{fk_repo}.new.find_#{singlename}(@form_object.#{f})&.#{code}"
        flds << "#{f}_label = @repo.find(:#{fk[:table]}, #{opts.classnames[:module]}::#{klassname}, @form_object.#{f})&.#{code}"
      end

      flds + fields_to_use.map do |f|
        fk = opts.table_meta.fk_lookup[f]
        if fk.nil?
          this_col = opts.table_meta.col_lookup[f]
          if this_col[:type] == :boolean
            "fields[:#{f}] = { renderer: :label, as_boolean: true }"
          else
            "fields[:#{f}] = { renderer: :label }"
          end
        else
          "fields[:#{f}] = { renderer: :label, with_value: #{f}_label, caption: '#{f.to_s.chomp('_id').split('_').map(&:capitalize).join(' ')}' }"
        end
      end
    end

    # bool == checkbox, fk == select etc
    def common_fields
      fields_to_use.map do |field|
        this_col = opts.table_meta.col_lookup[field]
        required = this_col[:allow_null] ? '' : ' required: true '
        if this_col.nil?
          "#{field}: {}"
        elsif this_col[:type] == :boolean # int: number, _id: select.
          "#{field}: { renderer: :checkbox }"
        elsif field.to_s.end_with?('_id')
          make_select(field, this_col[:allow_null])
        else
          "#{field}: {#{required}}"
        end
      end
    end

    def make_select(field, can_be_null)
      fk = opts.table_meta.fk_lookup[field]
      return "#{field}: {}" if fk.nil?
      singlename  = opts.inflector.singularize(fk[:table].to_s)
      klassname   = opts.inflector.camelize(singlename)
      fk_repo = "#{opts.classnames[:module]}::#{klassname}Repo"
      # get fk data & make select - or (if no fk....)
      tm = TableMeta.new(fk[:table])
      required = can_be_null ? '' : ', required: true'
      if tm.active_column_present?
        "#{field}: { renderer: :select, options: #{fk_repo}.new.for_select_#{fk[:table]}, disabled_options: #{fk_repo}.new.for_inactive_select_#{fk[:table]}, caption: '#{field.to_s.chomp('_id')}'#{required} }"
      else
        "#{field}: { renderer: :select, options: #{fk_repo}.new.for_select_#{fk[:table]}, caption: '#{field.to_s.chomp('_id').split('_').map(&:capitalize).join(' ')}'#{required} }"
      end
    end

    # use default values (or should the use of struct be changed to something that knows the db?)
    def struct_fields
      fields_to_use.map do |field|
        this_col = opts.table_meta.col_lookup[field]
        if this_col && this_col[:ruby_default]
          "#{field}: #{default_to_string(this_col[:ruby_default])}"
        else
          "#{field}: nil"
        end
      end
    end

    def default_to_string(default)
      default.is_a?(String) ? "'#{default}'" : default
    end
  end

  class TestMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      {
        interactor: test_interactor,
        repo: test_repo,
        route: test_route
      }
    end

    private

    def test_repo
      <<~RUBY
        # frozen_string_literal: true

        require File.join(File.expand_path('../../../../test', __dir__), 'test_helper')

        # rubocop:disable Metrics/ClassLength
        # rubocop:disable Metrics/AbcSize

        module #{opts.classnames[:module]}
          class Test#{opts.classnames[:repo]} < MiniTestWithHooks

            def test_for_selects
              assert_respond_to repo, :for_select_#{opts.has_short_name ? opts.singlename : opts.table}
            end

            def test_crud_calls
              assert_respond_to repo, :find_#{opts.singlename}
              assert_respond_to repo, :create_#{opts.singlename}
              assert_respond_to repo, :update_#{opts.singlename}
              assert_respond_to repo, :delete_#{opts.singlename}
            end

            private

            def repo
              #{opts.classnames[:repo]}.new
            end
          end
        end
        # rubocop:enable Metrics/ClassLength
        # rubocop:enable Metrics/AbcSize
      RUBY
    end

    def test_interactor
      <<~RUBY
        # frozen_string_literal: true

        require File.join(File.expand_path('../../../../test', __dir__), 'test_helper')

        # rubocop:disable Metrics/ClassLength
        # rubocop:disable Metrics/AbcSize

        module #{opts.classnames[:module]}
          class Test#{opts.classnames[:interactor]} < Minitest::Test
            def test_repo
              repo = interactor.repo
              # repo = interactor.send(:repo)
              assert repo.is_a?(#{opts.classnames[:namespaced_repo]})
            end

            private

            def interactor
              @interactor ||= #{opts.classnames[:interactor]}.new(current_user, {}, {}, {})
            end
          end
        end
        # rubocop:enable Metrics/ClassLength
        # rubocop:enable Metrics/AbcSize
      RUBY
    end

    def test_route
      base_route = "#{opts.applet}/#{opts.program}/"
      <<~RUBY
        # frozen_string_literal: true

        require File.join(File.expand_path('./../../../', __dir__), 'test_helper_for_routes')

        class Test#{opts.classnames[:class]}Routes < RouteTester

          INTERACTOR = #{opts.classnames[:namespaced_interactor]}

          def test_edit
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:view_prefix]}::Edit.stub(:call, bland_page) do
              get '#{base_route}#{opts.table}/1/edit', {}, 'rack.session' => { user_id: 1 }
            end
            expect_bland_page
          end

          def test_edit_fail
            authorise_fail!
            ensure_exists!(INTERACTOR)
            get '#{base_route}#{opts.table}/1/edit', {}, 'rack.session' => { user_id: 1 }
            expect_permission_error
          end

          def test_show
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:view_prefix]}::Show.stub(:call, bland_page) do
              get '#{base_route}#{opts.table}/1', {}, 'rack.session' => { user_id: 1 }
            end
            expect_bland_page
          end

          def test_show_fail
            authorise_fail!
            ensure_exists!(INTERACTOR)
            get '#{base_route}#{opts.table}/1', {}, 'rack.session' => { user_id: 1 }
            refute last_response.ok?
            assert_match(/permission/i, last_response.body)
          end

          def test_update
            authorise_pass!
            ensure_exists!(INTERACTOR)
            row_vals = Hash.new(1)
            #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:update_#{opts.singlename}).returns(ok_response(instance: row_vals))
            patch '#{base_route}#{opts.table}/1', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            expect_json_update_grid
          end

          def test_update_fail
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:update_#{opts.singlename}).returns(bad_response)
            #{opts.classnames[:view_prefix]}::Edit.stub(:call, bland_page) do
              patch '#{base_route}#{opts.table}/1', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            end
            expect_json_replace_dialog(has_error: true)
          end

          def test_delete
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:delete_#{opts.singlename}).returns(ok_response)
            delete '#{base_route}#{opts.table}/1', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            expect_json_delete_from_grid
          end
          #
          # def test_delete_fail
          #   authorise_pass!
          #   ensure_exists!(INTERACTOR)
          #   #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:delete_#{opts.singlename}).returns(bad_response)
          #   delete '#{base_route}#{opts.table}/1', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
          #   expect_bad_redirect
          # end

          def test_new
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:view_prefix]}::New.stub(:call, bland_page) do
              get  '#{base_route}#{opts.table}/new', {}, 'rack.session' => { user_id: 1 }
            end
            expect_bland_page
          end

          def test_new_fail
            authorise_fail!
            ensure_exists!(INTERACTOR)
            get '#{base_route}#{opts.table}/new', {}, 'rack.session' => { user_id: 1 }
            refute last_response.ok?
            assert_match(/permission/i, last_response.body)
          end

          def test_create
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:create_#{opts.singlename}).returns(ok_response)
            post '#{base_route}#{opts.table}', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            expect_ok_redirect
          end

          def test_create_remotely
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:create_#{opts.singlename}).returns(ok_response)
            post_as_fetch '#{base_route}#{opts.table}', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            expect_ok_json_redirect
          end

          def test_create_fail
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:create_#{opts.singlename}).returns(bad_response)
            #{opts.classnames[:view_prefix]}::New.stub(:call, bland_page) do
              post_as_fetch '#{base_route}#{opts.table}', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            end
            expect_bad_page

            #{opts.classnames[:view_prefix]}::New.stub(:call, bland_page) do
              post '#{base_route}#{opts.table}', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            end
            expect_bad_redirect(url: '/#{base_route}#{opts.table}/new')
          end

          def test_create_remotely_fail
            authorise_pass!
            ensure_exists!(INTERACTOR)
            #{opts.classnames[:namespaced_interactor]}.any_instance.stubs(:create_#{opts.singlename}).returns(bad_response)
            #{opts.classnames[:view_prefix]}::New.stub(:call, bland_page) do
              post_as_fetch '#{base_route}#{opts.table}', {}, 'rack.session' => { user_id: 1, last_grid_url: DEFAULT_LAST_GRID_URL }
            end
            expect_json_replace_dialog
          end
        end
      RUBY
    end
  end

  class ViewMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      {
        new: new_view,
        edit: edit_view,
        show: show_view
      }
    end

    private

    def fields_to_use
      opts.table_meta.columns_without(%i[id created_at updated_at active])
    end

    def form_fields
      fields_to_use.map { |f| "form.add_field :#{f}" }.join(UtilityFunctions.newline_and_spaces(14))
    end

    def needs_id
      opts.nested_route ? 'parent_id, ' : ''
    end

    def new_form_url
      if opts.nested_route
        "\"/#{opts.applet}/#{opts.program}/#{opts.nested_route}/\#{parent_id}/#{opts.table}\""
      else
        "'/#{opts.applet}/#{opts.program}/#{opts.table}'"
      end
    end

    def new_view
      <<~RUBY
        # frozen_string_literal: true

        module #{opts.classnames[:applet]}
          module #{opts.classnames[:program]}
            module #{opts.classnames[:class]}
              class New
                def self.call(#{needs_id}form_values: nil, form_errors: nil, remote: true) # rubocop:disable Metrics/AbcSize
                  ui_rule = UiRules::Compiler.new(:#{opts.singlename}, :new, form_values: form_values)
                  rules   = ui_rule.compile

                  layout = Crossbeams::Layout::Page.build(rules) do |page|
                    page.form_object ui_rule.form_object
                    page.form_values form_values
                    page.form_errors form_errors
                    page.form do |form|
                      form.action #{new_form_url}
                      form.remote! if remote
                      #{form_fields}
                    end
                  end

                  layout
                end
              end
            end
          end
        end
      RUBY
    end

    def edit_view
      <<~RUBY
        # frozen_string_literal: true

        module #{opts.classnames[:applet]}
          module #{opts.classnames[:program]}
            module #{opts.classnames[:class]}
              class Edit
                def self.call(id, form_values: nil, form_errors: nil) # rubocop:disable Metrics/AbcSize
                  ui_rule = UiRules::Compiler.new(:#{opts.singlename}, :edit, id: id, form_values: form_values)
                  rules   = ui_rule.compile

                  layout = Crossbeams::Layout::Page.build(rules) do |page|
                    page.form_object ui_rule.form_object
                    page.form_values form_values
                    page.form_errors form_errors
                    page.form do |form|
                      form.action "/#{opts.applet}/#{opts.program}/#{opts.table}/\#{id}"
                      form.remote!
                      form.method :update
                      #{form_fields}
                    end
                  end

                  layout
                end
              end
            end
          end
        end
      RUBY
    end

    def show_view
      <<~RUBY
        # frozen_string_literal: true

        module #{opts.classnames[:applet]}
          module #{opts.classnames[:program]}
            module #{opts.classnames[:class]}
              class Show
                def self.call(id)
                  ui_rule = UiRules::Compiler.new(:#{opts.singlename}, :show, id: id)
                  rules   = ui_rule.compile

                  layout = Crossbeams::Layout::Page.build(rules) do |page|
                    page.form_object ui_rule.form_object
                    page.form do |form|
                      form.view_only!
                      #{form_fields}
                    end
                  end

                  layout
                end
              end
            end
          end
        end
      RUBY
    end
  end

  class QueryMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
      @repo = DevelopmentApp::DevelopmentRepo.new
    end

    def call
      base_sql = <<~SQL
        SELECT #{columns}
        FROM #{opts.table}
        #{make_joins}
      SQL
      report = Crossbeams::Dataminer::Report.new(opts.table.split('_').map(&:capitalize).join(' '))
      report.sql = base_sql
      report
    end

    private

    def columns
      tab_cols = opts.table_meta.column_names.map { |col| "#{opts.table}.#{col}" }
      fk_cols  = []
      opts.table_meta.foreigns.each do |fk|
        if fk[:table] == :party_roles # Special treatment for party_role lookups to get party name
          fk[:columns].each do |fk_col|
            fk_cols << "fn_party_role_name(#{opts.table}.#{fk_col}) AS #{fk_col.sub(/_id$/, '')}"
          end
        else
          fk_col = get_representative_col_from_table(fk[:table])
          fk_cols << if opts.table_meta.column_names.include?(fk_col.to_sym)
                       "#{fk[:table]}.#{fk_col} AS #{fk[:table]}_#{fk_col}"
                     else
                       "#{fk[:table]}.#{fk_col}"
                     end
        end
      end
      (tab_cols + fk_cols).join(', ')
    end

    def get_representative_col_from_table(table)
      tab = TableMeta.new(table)
      tab.likely_label_field
    end

    def make_joins
      used_tables = Hash.new(0)
      opts.table_meta.foreigns.map do |fk|
        tab_alias = fk[:table]
        next if tab_alias == :party_roles # No join - usualy no need to join if using fn_party_role_name() function for party name
        cnt       = used_tables[fk[:table]] += 1
        tab_alias = "#{tab_alias}#{cnt}" if cnt > 1
        on_str    = make_on_clause(tab_alias, fk[:key], fk[:columns])
        out_join = nullable_column?(fk[:columns].first) ? 'LEFT ' : ''
        "#{out_join}JOIN #{fk[:table]} #{cnt > 1 ? tab_alias : ''} #{on_str}"
      end.join("\n")
    end

    def make_on_clause(tab_alias, keys, cols)
      res = []
      keys.each_with_index do |k, i|
        res << "#{i.zero? ? 'ON' : 'AND'} #{tab_alias}.#{k} = #{opts.table}.#{cols[i]}"
      end
      res.join("\n")
    end

    def nullable_column?(column)
      opts.table_meta.col_lookup[column][:allow_null]
    end
  end

  class DmQueryMaker < BaseService
    attr_reader :opts, :report
    def initialize(report, opts)
      @report     = Crossbeams::Dataminer::Report.new(report.caption)
      @report.sql = report.runnable_sql
      @opts       = opts
    end

    def call
      new_report = DmCreator.new(DB, report).modify_column_datatypes
      hide_cols = %w[id created_at updated_at]
      new_report.ordered_columns.each do |col|
        new_report.column(col.name).hide = true if hide_cols.include?(col.name) || col.name.end_with?('_id')
        if col.name.end_with?('_id') || opts.table_meta.indexed_columns.include?(col.name.to_sym)
          param = make_param_for(col)
          new_report.add_parameter_definition(param)
        end
      end
      new_report.to_hash.to_yaml
    end

    private

    def make_param_for(col)
      control_type = control_type_for(col)
      opts = {
        control_type: control_type,
        data_type: col.data_type,
        caption: col.caption
      }
      opts[:list_def] = make_list_def_for(col) if control_type == :list
      Crossbeams::Dataminer::QueryParameterDefinition.new(col.namespaced_name, opts)
    end

    def control_type_for(col)
      if col.name.end_with?('_id')
        if opts.table_meta.fk_lookup.empty? || opts.table_meta.fk_lookup[col.name.to_sym].nil?
          :text
        else
          :list
        end
      elsif %i[date datetime].include?(col.data_type)
        :daterange
      else
        :text
      end
    end

    def make_list_def_for(col)
      fk = opts.table_meta.fk_lookup[col.name.to_sym]
      table = fk[:table]
      key = fk[:key].first
      if table == :party_roles
        "SELECT fn_party_role_name(#{key}), #{key} FROM party_roles WHERE role_id = (SELECT id FROM roles WHERE name = 'ROLE_NAME_GOES_HERE')"
      else
        likely = get_representative_col_from_table(table)
        "SELECT #{likely}, #{key} FROM #{table} ORDER BY #{likely}"
      end
    end

    def get_representative_col_from_table(table)
      tab = TableMeta.new(table)
      tab.likely_label_field
    end
  end

  # generate a blank service?

  class AppletMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def call
      <<~RUBY
        # frozen_string_literal: true

        root_dir = File.expand_path('..', __dir__)
        Dir["\#{root_dir}/#{opts.applet}/entities/*.rb"].each { |f| require f }
        Dir["\#{root_dir}/#{opts.applet}/interactors/*.rb"].each { |f| require f }
        Dir["\#{root_dir}/#{opts.applet}/repositories/*.rb"].each { |f| require f }
        # Dir["\#{root_dir}/#{opts.applet}/services/*.rb"].each { |f| require f }
        Dir["\#{root_dir}/#{opts.applet}/ui_rules/*.rb"].each { |f| require f }
        Dir["\#{root_dir}/#{opts.applet}/validations/*.rb"].each { |f| require f }
        Dir["\#{root_dir}/#{opts.applet}/views/**/*.rb"].each { |f| require f }

        module #{opts.classnames[:module]}
        end
      RUBY
    end
  end

  class MenuMaker < BaseService
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end

    def titleize(str)
      str.split(' ').map(&:capitalize).join(' ')
    end

    def call
      <<~SQL
        INSERT INTO functional_areas (functional_area_name) VALUES ('#{titleize(opts.applet)}');

        INSERT INTO programs (program_name, program_sequence, functional_area_id)
        VALUES ('#{titleize(opts.program_text)}', 1, (SELECT id FROM functional_areas
                                                      WHERE functional_area_name = '#{titleize(opts.applet)}'));

        INSERT INTO programs_webapps(program_id, webapp) VALUES (
              (SELECT id FROM programs
               WHERE program_name = '#{titleize(opts.program_text)}'
                 AND functional_area_id = (SELECT id FROM functional_areas
                                           WHERE functional_area_name = '#{titleize(opts.applet)}')),
               '#{opts.classnames[:roda_class]}');

        -- NEW menu item
        /*
        INSERT INTO program_functions (program_id, program_function_name, url, program_function_sequence)
        VALUES ((SELECT id FROM programs WHERE program_name = '#{titleize(opts.program_text)}'
                 AND functional_area_id = (SELECT id FROM functional_areas
                                           WHERE functional_area_name = '#{titleize(opts.applet)}')),
                 'New #{opts.classnames[:class]}', '/#{opts.applet}/#{opts.program}/#{opts.table}/new', 1);
        */

        -- LIST menu item
        INSERT INTO program_functions (program_id, program_function_name, url, program_function_sequence)
        VALUES ((SELECT id FROM programs WHERE program_name = '#{titleize(opts.program_text)}'
                 AND functional_area_id = (SELECT id FROM functional_areas
                                           WHERE functional_area_name = '#{titleize(opts.applet)}')),
                 '#{opts.table.capitalize}', '/list/#{opts.table}', 2);

        -- SEARCH menu item
        /*
        INSERT INTO program_functions (program_id, program_function_name, url, program_function_sequence)
        VALUES ((SELECT id FROM programs WHERE program_name = '#{titleize(opts.program_text)}'
                 AND functional_area_id = (SELECT id FROM functional_areas
                                           WHERE functional_area_name = '#{titleize(opts.applet)}')),
                 'Search #{opts.table.capitalize}', '/search/#{opts.table}', 2);
        */
      SQL
    end
  end
end
# rubocop:enable Metrics/AbcSize
