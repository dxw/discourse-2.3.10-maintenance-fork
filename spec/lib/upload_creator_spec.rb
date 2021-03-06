# frozen_string_literal: true

require 'rails_helper'
require 'file_store/s3_store'

RSpec.describe UploadCreator do
  fab!(:user) { Fabricate(:user) }

  describe '#create_for' do
    describe 'when upload is not an image' do
      before do
        SiteSetting.authorized_extensions = 'txt'
      end

      let(:filename) { "utf-8.txt" }
      let(:file) { file_from_fixtures(filename, "encodings") }

      it 'should store the upload with the right extension' do
        expect do
          UploadCreator.new(file, "utf-8\n.txt").create_for(user.id)
        end.to change { Upload.count }.by(1)

        upload = Upload.last

        expect(upload.extension).to eq('txt')
        expect(File.extname(upload.url)).to eq('.txt')
        expect(upload.original_filename).to eq('utf-8.txt')
        expect(user.user_uploads.count).to eq(1)
        expect(upload.user_uploads.count).to eq(1)

        user2 = Fabricate(:user)

        expect do
          UploadCreator.new(file, "utf-8\n.txt").create_for(user2.id)
        end.to change { Upload.count }.by(0)

        expect(user.user_uploads.count).to eq(1)
        expect(user2.user_uploads.count).to eq(1)
        expect(upload.user_uploads.count).to eq(2)
      end
    end

    describe 'when image is not authorized' do
      describe 'when image is for site setting' do
        let(:filename) { 'logo.png' }
        let(:file) { file_from_fixtures(filename) }

        before do
          SiteSetting.authorized_extensions = 'jpg'
        end

        it 'should create the right upload' do
          upload = UploadCreator.new(file, filename,
            for_site_setting: true
          ).create_for(Discourse.system_user.id)

          expect(upload.persisted?).to eq(true)
          expect(upload.original_filename).to eq(filename)
        end
      end
    end

    describe 'when image has the wrong extension' do
      let(:filename) { "png_as.bin" }
      let(:file) { file_from_fixtures(filename) }

      it 'should store the upload with the right extension' do
        expect do
          UploadCreator.new(file, filename,
            force_optimize: true,
            type: UploadCreator::TYPES_TO_CROP.first
          ).create_for(user.id)
        end.to change { Upload.count }.by(1)

        upload = Upload.last

        expect(upload.extension).to eq('png')
        expect(File.extname(upload.url)).to eq('.png')
        expect(upload.original_filename).to eq('png_as.png')
      end

      describe 'for webp format' do
        before do
          SiteSetting.authorized_extensions = '.webp|.bin'
        end

        let(:filename) { "webp_as.bin" }
        let(:file) { file_from_fixtures(filename) }

        it 'should not correct the coerce filename' do
          expect do
            UploadCreator.new(file, filename).create_for(user.id)
          end.to change { Upload.count }.by(1)

          upload = Upload.last

          expect(upload.extension).to eq('bin')
          expect(File.extname(upload.url)).to eq('.bin')
          expect(upload.original_filename).to eq('webp_as.bin')
        end
      end
    end

    describe 'pngquant' do
      let(:filename) { "pngquant.png" }
      let(:file) { file_from_fixtures(filename) }

      it 'should apply pngquant to optimized images' do
        upload = UploadCreator.new(file, filename,
          pasted: true,
          force_optimize: true
        ).create_for(user.id)

        # no optimisation possible without losing details
        expect(upload.filesize).to eq(9558)

        thumbnail_size = upload.get_optimized_image(upload.width, upload.height, {}).filesize

        # pngquant will lose some colors causing some extra size reduction
        expect(thumbnail_size).to be < 7500
      end

    end

    describe 'converting to jpeg' do
      let(:filename) { "should_be_jpeg.png" }
      let(:file) { file_from_fixtures(filename) }

      let(:small_filename) { "logo.png" }
      let(:small_file) { file_from_fixtures(small_filename) }

      before do
        SiteSetting.png_to_jpg_quality = 1
      end

      it 'should not store file as jpeg if it does not meet absolute byte saving requirements' do

        # logo.png is 2297 bytes, converting to jpeg saves 30% but does not meet
        # the absolute savings required of 25_000 bytes, if you save less than that
        # skip this

        expect do
          UploadCreator.new(small_file, small_filename,
            pasted: true,
            force_optimize: true
          ).create_for(user.id)
        end.to change { Upload.count }.by(1)

        upload = Upload.last

        expect(upload.extension).to eq('png')
        expect(File.extname(upload.url)).to eq('.png')
        expect(upload.original_filename).to eq('logo.png')

      end

      it 'should store the upload with the right extension' do
        expect do
          UploadCreator.new(file, filename,
            pasted: true,
            force_optimize: true
          ).create_for(user.id)
        end.to change { Upload.count }.by(1)

        upload = Upload.last

        expect(upload.extension).to eq('jpeg')
        expect(File.extname(upload.url)).to eq('.jpeg')
        expect(upload.original_filename).to eq('should_be_jpeg.jpg')
      end
    end

    describe 'private uploads' do
      let(:filename) { "small.pdf" }
      let(:file) { file_from_fixtures(filename, "pdf") }

      before do
        SiteSetting.prevent_anons_from_downloading_files = true
        SiteSetting.authorized_extensions = 'pdf|svg|jpg'
      end

      it 'should mark uploads as private' do
        upload = UploadCreator.new(file, filename).create_for(user.id)
        stored_upload = Upload.last

        expect(stored_upload.private?).to eq(true)
      end

      it 'should not mark theme uploads as private' do
        fname = "custom-theme-icon-sprite.svg"
        upload = UploadCreator.new(file_from_fixtures(fname), fname, for_theme: true).create_for(-1)

        expect(upload.private?).to eq(false)
      end

      it 'should not mark image uploads as private' do
        fname = "logo.jpg"
        upload = UploadCreator.new(file_from_fixtures(fname), fname).create_for(user.id)
        stored_upload = Upload.last

        expect(stored_upload.original_filename).to eq(fname)
        expect(stored_upload.private?).to eq(false)
      end
    end

    describe 'uploading to s3' do
      let(:filename) { "should_be_jpeg.png" }
      let(:file) { file_from_fixtures(filename) }
      let(:pdf_filename) { "small.pdf" }
      let(:pdf_file) { file_from_fixtures(pdf_filename, "pdf") }

      before do
        SiteSetting.s3_upload_bucket = "s3-upload-bucket"
        SiteSetting.s3_access_key_id = "s3-access-key-id"
        SiteSetting.s3_secret_access_key = "s3-secret-access-key"
        SiteSetting.s3_region = 'us-west-1'
        SiteSetting.enable_s3_uploads = true

        store = FileStore::S3Store.new
        s3_helper = store.instance_variable_get(:@s3_helper)
        client = Aws::S3::Client.new(stub_responses: true)
        s3_helper.stubs(:s3_client).returns(client)
        Discourse.stubs(:store).returns(store)
      end

      it 'should store the file and return etag' do
        expect {
          UploadCreator.new(file, filename).create_for(user.id)
        }.to change { Upload.count }.by(1)

        upload = Upload.last

        expect(upload.etag).to eq('ETag')
      end

      it 'should return signed URL for private uploads in S3' do
        SiteSetting.prevent_anons_from_downloading_files = true
        SiteSetting.authorized_extensions = 'pdf'

        upload = UploadCreator.new(pdf_file, pdf_filename).create_for(user.id)
        stored_upload = Upload.last
        signed_url = Discourse.store.url_for(stored_upload)

        expect(stored_upload.private?).to eq(true)
        expect(stored_upload.url).not_to eq(signed_url)
        expect(signed_url).to match(/Amz-Credential/)
      end
    end
  end

  describe '#whitelist_svg!' do
    let(:file) do
      file = Tempfile.new
      file.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="200px" height="200px" onload="alert(location)">
        </svg>
      XML
      file.rewind
      file
    end

    it 'removes event handlers' do
      begin
        UploadCreator.new(file, 'file.svg').whitelist_svg!
        expect(file.read).not_to include('onload')
      ensure
        file.unlink
      end
    end
  end
end
