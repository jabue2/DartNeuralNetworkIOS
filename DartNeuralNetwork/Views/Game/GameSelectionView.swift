import SwiftUI

// View that allows users to select different dart game modes
struct GameSelectionView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Text("Select Game Mode")
                    .font(.largeTitle)
                    .bold()
                    .padding(.top)

                // 301 game mode - players start with 301 points and aim to reach exactly zero
                NavigationLink(destination: DartsGameLiveView(startingScore: 301)) {
                    Text("301")
                        .font(.title)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.horizontal)
                }

                // 501 game mode - players start with 501 points and aim to reach exactly zero
                NavigationLink(destination: DartsGameLiveView(startingScore: 501)) {
                    Text("501")
                        .font(.title)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .navigationBarTitle("Darts Game Selection", displayMode: .inline)
        }
    }
}

struct GameSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        GameSelectionView()
    }
}
