module Jekyll
  module S3
    class Uploader

      SITE_DIR = "_site"
      CONFIGURATION_FILE = '_jekyll_s3.yml'
      CONFIGURATION_FILE_TEMPLATE = <<-EOF
s3_id: YOUR_AWS_S3_ACCESS_KEY_ID
s3_secret: YOUR_AWS_S3_SECRET_ACCESS_KEY
s3_bucket: your.blog.bucket.com
cloudfront_distribution_id: YOUR_CLOUDFRONT_DIST_ID (OPTIONAL)
      EOF

      def self.run!
        new.run!
      end

      def run!
        check_jekyll_project!
        check_s3_configuration!
        load_configuration
        upload_to_s3!
        invalidate_cf_dist_if_configured!
      end

      protected

      def invalidate_cf_dist_if_configured!
        cloudfront_configured = @cloudfront_distribution_id != nil && @cloudfront_distribution_id != ''
        Jekyll::Cloudfront::Invalidator.invalidate(
          @s3_id, @s3_secret, @s3_bucket, @cloudfront_distribution_id
          ) if cloudfront_configured
      end

      def run_with_retry
        begin
          yield
        rescue AWS::S3::RequestTimeout => e
          $stderr.puts "Exception Occurred:  #{e.message} (#{e.class})  Retrying in 5 seconds..."
          sleep 5
          retry
        end
      end

      def local_files
        dir = @production_directory || SITE_DIR
        paths = []

        files = Dir[dir + '/**/*']
        files = files.delete_if { |f|
          File.directory?(f)
        }.map { |f|
          f.gsub(dir + '/', '')
        }

        if @config['exclude_files']
          patterns = @config['exclude_files'].map do |p|
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

      def customize_file_metadata(file)
        data = { :access => 'public-read' }
        expiry = find_matching_expires_header(file)
        if expiry
          data[:expiry] = expiry
        end
        data
      end

      def find_matching_expires_header(file)
        headers = @config['expire_headers']
        raise headers.to_yaml
        headers.each do |expire|
          pattern = Regexp.new expire['pattern']
          value = expire['value']
          if value =~ pattern
            return value
          end
        end
      end

      # Please spec me!
      def upload_to_s3!
        puts "Deploying _site/* to #{@s3_bucket}"

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

        dir = @production_directory || SITE_DIR
        to_upload = local_files
        to_upload.each do |f|
          run_with_retry do
            path = "#{dir}/#{f}"
            metadata = customize_file_metadata(path)
            raise metadata.to_yaml
            if AWS::S3::S3Object.store(f, open(path), @s3_bucket, metadata)
              puts("Upload #{f}: Success!")
            else
              puts("Upload #{f}: FAILURE!")
            end
          end
        end

        to_delete = remote_files - local_files

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

        puts "Done! Go visit: http://#{@s3_bucket}.s3.amazonaws.com/index.html"
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

        @s3_id = @config['s3_id']
        @s3_secret = @config['s3_secret']
        @s3_bucket = @config['s3_bucket']
        @cloudfront_distribution_id = @config['cloudfront_distribution_id']
        @production_directory = @config['production_directory']

        raise MalformedConfigurationFileError unless
          [@s3_id, @s3_secret, @s3_bucket].select { |k| k.nil? || k == '' }.empty?
      end

      def create_template_configuration_file
        File.open(CONFIGURATION_FILE, 'w') { |f| f.write(CONFIGURATION_FILE_TEMPLATE) }

      end
    end
  end
end
