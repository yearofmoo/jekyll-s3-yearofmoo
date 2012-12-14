module Jekyll
  module S3
    class Uploader

      SITE_DIR = "_site"
      CONFIGURATION_FILE = '_jekyll_s3.yml'
      CONFIGURATION_FILE_SECRET = '_jekyll_s3_secret.yml'
      CONFIGURATION_FILE_TEMPLATE = <<-EOF
s3_id: YOUR_AWS_S3_ACCESS_KEY_ID
s3_secret: YOUR_AWS_S3_SECRET_ACCESS_KEY
s3_bucket: your.blog.bucket.com
cloudfront_distribution_id: YOUR_CLOUDFRONT_DIST_ID (OPTIONAL)
      EOF

      def self.run!(campaign=nil)
        new.run!(campaign)
      end

      def run!(campaign=nil)
        check_jekyll_project!
        check_s3_configuration!
        load_configuration
        upload_to_s3!(campaign)
      end

      protected

      def run_with_retry
        begin
          yield
        rescue AWS::S3::RequestTimeout => e
          $stderr.puts "Exception Occurred:  #{e.message} (#{e.class})  Retrying in 5 seconds..."
          sleep 5
          retry
        end
      end

      def local_files(campaign=nil)
        dir = @production_directory || SITE_DIR
        paths = []

        campaign = @config['campaigns'][campaign]
        if campaign
          include_pattern = campaign['include_files']
          exclude_pattern = campaign['exclude_files']
        end

        include_pattern ||= '**/*'
        exclude_pattern ||= nil

        if include_pattern.is_a?(Array)
          files = []
          include_pattern.each do |pat|
            files |= Dir[dir + '/' + pat]
          end
        else
          files = Dir[dir + '/' + include_pattern]
        end

        files = files.delete_if { |f|
          File.directory?(f)
        }.map { |f|
          f.gsub(dir + '/', '')
        }

        if exclude_pattern
          exclude_pattern = exclude_pattern.is_a?(Array) ? exclude_pattern : [exclude_pattern]
        end

        exclude_pattern ||= []

        p = @config['exclude_files']
        if p
          p = p.is_a?(Array) ? p : [p]
          exclude_pattern |= p
        end

        if exclude_pattern.length > 0
          patterns = exclude_pattern.map do |p|
            Regexp.new(p)
          end
          files.each do |file|
            found = true
            patterns.each do |pattern|
              found = false if file =~ pattern 
            end
            paths.push(file) if found
          end
        else
          paths = files
        end

        paths
      end

      def find_matching_content_type(file)
        ext = File.extname(file).downcase
        if ext == '.html' || ext == '.xview'
          return 'text/html'
        end
        if file =~ /\.js\.gz/
          return 'application/javascript'
        end
        if file =~ /\.css\.gz/
          return 'text/css'
        end
        if file =~ /\.html\.gz/
          return 'text/html'
        end
        return nil
      end

      def customize_file_metadata(file)
        data = { :access => 'public-read' }

        headers = @config['headers']
        headers.each do |h|
          pattern = h['pattern']
          header  = h['header']
          value   = h['value']
          pattern = Regexp.new(pattern)
          if file =~ pattern
            data[header] = value
          end
        end

        content_type = find_matching_content_type(file)
        if content_type
          data['Content-Type'] = content_type
        end

        data
      end


      # Please spec me!
      def upload_to_s3!(campaign=nil)
        if campaign
          data = @config['campaigns'][campaign]
        end

        dir = @production_directory || SITE_DIR

        if data
          remove_files = false
          puts "Deploying Campaign = \"#{campaign}\" to #{@s3_bucket}"
        else
          remove_files = true
          puts "Deploying Files = \"#{dir}/*\" to #{@s3_bucket}"
        end

        AWS::S3::Base.establish_connection!(
            :access_key_id     => @s3_id,
            :secret_access_key => @s3_secret,
            :use_ssl => true
        )
        unless AWS::S3::Service.buckets.map(&:name).include?(@s3_bucket)
          puts("Creating bucket #{@s3_bucket}")
          AWS::S3::Bucket.create(@s3_bucket)
        end

        bucket = AWS::S3::Bucket.find(@s3_bucket)

        remote_files = bucket.objects.map { |f| f.key }

        to_upload = local_files(campaign)
        to_upload.each do |f|
          run_with_retry do
            path = "#{dir}/#{f}"
            metadata = customize_file_metadata(path)
            if AWS::S3::S3Object.store(f, open(path), @s3_bucket, metadata)
              puts("Upload #{f}: Success!")
            else
              puts("Upload #{f}: FAILURE!")
            end
          end
        end

        if remove_files
          to_delete = remote_files - to_upload

          delete_all = false
          keep_all = false
          to_delete.each do |f|
            delete = false
            keep = false
            until delete || delete_all || keep || keep_all
              puts "#{f} is on S3 but not in your _site directory anymore. Do you want to [d]elete, [D]elete all, [k]eep, [K]eep all?"
              case STDIN.gets.chomp
              when 'd' then delete = true
              when 'D' then delete_all = true
              when 'k' then keep = true
              when 'K' then keep_all = true
              end
            end
            if (delete_all || delete) && !(keep_all || keep)
              run_with_retry do
                if AWS::S3::S3Object.delete(f, @s3_bucket)
                  puts("Delete #{f}: Success!")
                else
                  puts("Delete #{f}: FAILURE!")
                end
              end
            end
          end
        end

        domain = 'http://#{@s3_bucket}.s3.amazonaws.com/index.html'
        if @config['www']
          domain = @config['www']
        end
        puts "Done! Go visit: #{domain}"

        true
      end

      def check_jekyll_project!
        raise NotAJekyllProjectError unless File.directory?(SITE_DIR)
      end

      # Raise NoConfigurationFileError if the configuration file does not exists
      def check_s3_configuration!
        unless File.exists?(CONFIGURATION_FILE)
          create_template_configuration_file
          raise NoConfigurationFileError
        end
      end

      # Load configuration from _jekyll_s3.yml
      # Raise MalformedConfigurationFileError if the configuration file does not contain the keys we expect
      def load_configuration
        @config = YAML.load_file(CONFIGURATION_FILE) rescue nil
        raise MalformedConfigurationFileError unless @config

        @config2 = YAML.load_file(CONFIGURATION_FILE_SECRET) rescue nil
        raise MalformedConfigurationFileError unless @config2

        @production_directory = @config['production_directory']

        @s3_id                        = @config2['s3_id']
        @s3_secret                    = @config2['s3_secret']
        @s3_bucket                    = @config2['s3_bucket']
        @cloudfront_distribution_id   = @config2['cloudfront_distribution_id']

        raise MalformedConfigurationFileError unless
          [@s3_id, @s3_secret, @s3_bucket].select { |k| k.nil? || k == '' }.empty?
      end

      def create_template_configuration_file
        File.open(CONFIGURATION_FILE, 'w') { |f| f.write(CONFIGURATION_FILE_TEMPLATE) }

      end
    end
  end
end
