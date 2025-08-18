RSpec.describe 'Integration Tests' do

  describe 'Service basics' do
    it 'routes WI' do
      # https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/7/44/25
      get '/wi/7/44/25'
      expect(last_response.status).to eq(200)
    end
    it 'returns style for WI' do
      get '/wi'
      expect(last_response.status).to eq(200)
      body = JSON last_response.body, symbolize_names: true
      expect(body.dig :sources, :raster, :tiles, 0).to match(%r[^http://localhost/wi/{z}/{x}/{y}])
    end

    it 'respond to Healthcheck' do
      get '/healthcheck'
      expect(last_response.status).to eq(200)
    end
  end
end