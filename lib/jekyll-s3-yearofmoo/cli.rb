module Jekyll
  module S3
    class CLI
      def self.run!(campaign=nil)
        Uploader.run!(campaign)
      rescue JekyllS3Error => e
        puts e.message
        exit 1
      end
    end
  end
end
