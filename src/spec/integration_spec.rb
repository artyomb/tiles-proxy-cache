RSpec.describe 'Integration Tests' do

  describe 'Service basics' do
    it 'responds to healthcheck' do
      get '/healthcheck'
      expect(last_response.status).to eq(200)
    end

    it 'returns 404 for unknown route' do
      get '/unknown_route/1/2/3'
      expect(last_response.status).to eq(404)
    end

    it 'returns main page' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Tiles Proxy Cache')
    end
  end
end
