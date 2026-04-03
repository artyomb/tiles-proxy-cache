RSpec.describe 'Integration Tests' do
  let(:source) { ROUTES.keys.first.to_s }

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

  describe 'Autoscan API' do
    it 'restarts autoscan for source with enabled autoscan' do
      post "/api/autoscan/#{source}/restart"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body['success']).to be(true)
      expect(body).to have_key('running')
    end

    it 'returns 400 when autoscan is disabled for source' do
      route = ROUTES[source.to_sym]
      loader = route[:autoscan_loader]
      allow(loader).to receive(:enabled?).and_return(false)

      post "/api/autoscan/#{source}/restart"

      expect(last_response.status).to eq(400)
      expect(last_response.body).to include('Autoscan not enabled')
    end

    it 'returns 404 for unknown source' do
      post '/api/autoscan/unknown_source/restart'
      expect(last_response.status).to eq(404)
    end
  end
end
